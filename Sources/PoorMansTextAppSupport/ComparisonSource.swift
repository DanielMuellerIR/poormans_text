import Foundation
import Darwin
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import PoorMansTextCore

struct ComparisonSourceSnapshot: Sendable {
    let data: Data?
    let format: InputFormat
    static let maximumPreviewBytes = 128 * 1_048_576

    enum Failure: Error { case missing, changed, unverified, limit, unreadable }

    static func read(_ result: ConversionResult) throws -> Self {
        guard let expected = result.sourceIdentity, let digest = expected.sha256, let expectedCount = expected.byteCount,
              expectedCount >= 0 else { throw Failure.unverified }
        guard expectedCount <= 1_073_741_824 else { throw Failure.limit }
        let descriptor = open(result.inputURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw errno == ENOENT ? Failure.missing : Failure.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw Failure.unreadable }
        let capture = (result.format == .pdf || result.format == .image) && expectedCount <= maximumPreviewBytes
        var data = Data(), hash = SHA256(), count = 0
        while count <= expectedCount {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(262_144, expectedCount + 1 - count)), !chunk.isEmpty else { break }
            count += chunk.count; hash.update(data: chunk)
            if capture { data.append(chunk) }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              count == expectedCount, hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw Failure.changed }
        return Self(data: capture ? data : nil, format: result.format)
    }
}

/// Rasterbilder verhindern interaktive PDF-Aktionen und werden ausschließlich
/// aus den Bytes erzeugt, deren Hash zum Konvertierungsergebnis passt.
actor ComparisonSourceRenderer {
    private let snapshot: ComparisonSourceSnapshot
    private var pdf: PDFDocument?
    private var image: CGImageSource?
    init(_ snapshot: ComparisonSourceSnapshot) { self.snapshot = snapshot }

    func prepare() throws -> Int {
        guard let data = snapshot.data else { throw ComparisonSourceSnapshot.Failure.limit }
        if snapshot.format == .pdf {
            guard let document = PDFDocument(data: data), !document.isLocked, (1...100_000).contains(document.pageCount) else {
                throw ComparisonSourceSnapshot.Failure.unreadable
            }
            pdf = document; return document.pageCount
        }
        guard snapshot.format == .image,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP].contains(where: { $0.identifier == type }),
              (1...1000).contains(CGImageSourceGetCount(source)) else { throw ComparisonSourceSnapshot.Failure.unreadable }
        image = source; return CGImageSourceGetCount(source)
    }

    func render(_ number: Int) throws -> Data {
        try Task.checkCancellation()
        let bitmap: CGImage
        if let pdf, number > 0, let page = pdf.page(at: number - 1) {
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw ComparisonSourceSnapshot.Failure.unreadable
            }
            let scale = min(2048 / bounds.width, 2048 / bounds.height)
            let thumbnail = page.thumbnail(of: NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale)), for: .mediaBox)
            guard let cg = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ComparisonSourceSnapshot.Failure.unreadable }
            bitmap = cg
        } else if let image, number > 0, number <= CGImageSourceGetCount(image),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, number - 1, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 64_000_000 / height,
                  let cg = CGImageSourceCreateThumbnailAtIndex(image, number - 1, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) {
            bitmap = cg
        } else { throw ComparisonSourceSnapshot.Failure.unreadable }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ComparisonSourceSnapshot.Failure.unreadable
        }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 32 * 1_048_576 else { throw ComparisonSourceSnapshot.Failure.limit }
        return data as Data
    }
}

final class ComparisonSourceWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    private let sources: [DispatchSourceFileSystemObject]
    var hasChanged: Bool { lock.withLock { changed } }

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        var sources: [DispatchSourceFileSystemObject] = []
        for path in [url.path, url.deletingLastPathComponent().path] {
            let descriptor = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .global(qos: .utility))
            source.setCancelHandler { close(descriptor) }
            sources.append(source)
        }
        self.sources = sources
        for source in sources {
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.changed = true }
                onChange()
            }
            source.resume()
        }
    }
    deinit { sources.forEach { $0.cancel() } }
}
