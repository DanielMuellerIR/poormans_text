import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Nur registrierte Ergebnis-Assets. `openat` bindet jeden Bestandteil an den
/// gehaltenen Ergebnisordner; kein nachträglich untergeschobener Symlink führt hinaus.
public final class PreviewAssets: @unchecked Sendable {
    public let token = UUID().uuidString.lowercased()
    private let directory: Int32
    private let paths: [String]
    public let filesTruncated: Bool
    private let identifiers: [String: Int]
    private let lock = NSLock()
    private var cache: [Int: Data] = [:]
    private var cachedBytes = 0
    public static let maximumSourceBytes = 16 * 1_048_576
    public static let maximumPreviewBytes = 64 * 1_048_576

    public init(outputDirectory: URL, assets: [URL]) throws {
        let root = outputDirectory.standardizedFileURL.path
        let descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw PreviewAssetError.unavailable }
        var paths: [String] = []
        var identifiers: [String: Int] = [:]
        for asset in assets.prefix(1024) {
            let path = asset.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            let relative = String(path.dropFirst(root.count + 1))
            guard Self.components(relative) != nil, identifiers[relative] == nil else { continue }
            identifiers[relative] = paths.count
            paths.append(relative)
        }
        filesTruncated = assets.count > 1024
        directory = descriptor
        self.paths = paths
        self.identifiers = identifiers
    }

    deinit { close(directory) }

    public var localFiles: [String] { paths }

    public func previewFile(_ path: String) throws -> LocalFilePreview {
        guard identifiers[path] != nil else { throw PreviewAssetError.unavailable }
        if path.lowercased().hasSuffix(".txt") {
            let data = try read(path)
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { return .unsupported }
            return .text(String(decoding: data.prefix(262_144), as: UTF8.self), truncated: data.count > 262_144)
        }
        if path.lowercased().hasSuffix(".pdf") {
            let data = try read(path)
            guard data.starts(with: Data("%PDF-".utf8)), let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider), !document.isEncrypted,
                  let page = document.page(at: 1) else { return .unsupported }
            let bounds = page.getBoxRect(.cropBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return .unsupported }
            let scale = min(2048 / bounds.width, 2048 / bounds.height, 2)
            let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PreviewAssetError.limit }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
            // Nur die erste Seite zeichnen; PDF-Links und Aktionen nie an eine interaktive Ansicht geben.
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw PreviewAssetError.unsupportedImage }
            return .pdf(try Self.png(image), pageCount: document.numberOfPages)
        }
        guard let url = url(for: path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") else { throw PreviewAssetError.unavailable }
        let data = try read(path)
        guard Self.hasRasterSignature(data) else { return .unsupported }
        return .image(try thumbnail(for: url))
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PreviewAssetError.unsupportedImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= maximumSourceBytes else { throw PreviewAssetError.limit }
        return data as Data
    }

    public func url(for target: String) -> URL? {
        guard !target.hasPrefix("/"), !target.contains("\\"), !target.contains("?"), !target.contains("#"),
              URLComponents(string: target)?.scheme == nil,
              let decoded = target.removingPercentEncoding, Self.components(decoded) != nil,
              let id = identifiers[decoded] else { return nil }
        return URL(string: "pmt-preview://\(token)/\(id)")
    }

    public func thumbnail(for url: URL) throws -> Data {
        guard url.scheme == "pmt-preview", url.host == token, url.query == nil, url.fragment == nil,
              let id = Int(url.path.dropFirst()), url.path == "/\(id)", paths.indices.contains(id) else {
            throw PreviewAssetError.unavailable
        }
        return try lock.withLock {
            if let data = cache[id] { return data }
            let data = try read(paths[id])
            guard Self.hasRasterSignature(data),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(source) as String?,
                  [UTType.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP].contains(where: { $0.identifier == type }),
                  (1...1000).contains(CGImageSourceGetCount(source)),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 64_000_000 / height,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw PreviewAssetError.unsupportedImage }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
                throw PreviewAssetError.unsupportedImage
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), encoded.length <= Self.maximumSourceBytes,
                  encoded.length <= Self.maximumPreviewBytes - cachedBytes else { throw PreviewAssetError.limit }
            let result = encoded as Data
            cachedBytes += result.count; cache[id] = result
            return result
        }
    }

    private func read(_ path: String) throws -> Data {
        guard let components = Self.components(path) else { throw PreviewAssetError.unavailable }
        var current = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw PreviewAssetError.unavailable }
        defer { close(current) }
        for component in components.dropLast() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard next >= 0 else { throw PreviewAssetError.unavailable }
            close(current); current = next
        }
        let file = openat(current, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw PreviewAssetError.unavailable }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Self.maximumSourceBytes else { throw PreviewAssetError.limit }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 262_144)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, count <= Self.maximumSourceBytes - result.count else { throw PreviewAssetError.limit }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func components(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components
    }

    private static func hasRasterSignature(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10]) || bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) || bytes.starts(with: Array("BM".utf8)) { return true }
        if [[0x49, 0x49, 0x2A, 0], [0x4D, 0x4D, 0, 0x2A], [0x49, 0x49, 0x2B, 0], [0x4D, 0x4D, 0, 0x2B]].contains(where: { bytes.starts(with: $0.map(UInt8.init)) }) { return true }
        if bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF", String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP" { return true }
        return bytes.count >= 12 && String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp"
            && ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(String(decoding: bytes[8..<12], as: UTF8.self))
    }
}

public enum PreviewAssetError: Error { case unavailable, unsupportedImage, limit }

public enum LocalFilePreview: Sendable {
    case image(Data)
    case pdf(Data, pageCount: Int)
    case text(String, truncated: Bool)
    case unsupported
}
