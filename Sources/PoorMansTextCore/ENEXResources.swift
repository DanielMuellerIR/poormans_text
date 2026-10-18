import CryptoKit
import CoreGraphics
import Foundation
import ImageIO

struct ENEXResources {
    static let maximumResourceBytes = 12 * 1_048_576
    static let maximumResourcesPerNote = 1024
    struct Budget {
        var resources = 10_000
        var bytes = 64 * 1_048_576
        var pixels = 64_000_000
        var inspectedTypes: [String: (fileExtension: String, image: Bool)] = [:]
        mutating func consume(_ count: Int) throws {
            guard count <= bytes else { throw ImportFailure("the ENEX resources exceed their total byte budget") }
            bytes -= count
        }
    }

    struct Resource {
        let index: Int
        let mime: String
        let hash: String
        let data: Data
        let displayName: String
        let path: String
        let image: Bool
        let cid: String
    }
    let records: [Resource]
    let assetPaths: [String]
    let appendix: String
    let warnings: [ConversionWarning]
    private let byHash: [String: [Resource]]
    init(records: [Resource], assetPaths: [String], appendix: String, warnings: [ConversionWarning]) {
        self.records = records
        self.assetPaths = assetPaths
        self.appendix = appendix
        self.warnings = warnings
        self.byHash = Dictionary(grouping: records, by: \.hash)
    }
    var subresources: [String: HTMLImageSourceResolver.Subresource] {
        Dictionary(uniqueKeysWithValues: records.filter(\.image).map { ($0.cid, .init(data: $0.data, mimeType: $0.mime)) })
    }

    static func stage(_ note: ENEXReader.Note, context: AdapterConversionContext, budget: inout Budget) throws -> ENEXResources {
        let nodes = note.node.elements("resource", namespace: "")
        guard nodes.count <= maximumResourcesPerNote else { throw ImportFailure("the ENEX note exceeds its resource count limit") }
        guard !nodes.isEmpty else { return .init(records: [], assetPaths: [], appendix: "", warnings: []) }
        let directory = context.stagedOutputDirectory.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var records: [Resource] = []
        var paths: [String] = []
        var appendix = "\n\n## Resources\n\n"
        var warnings: [ConversionWarning] = []
        var cidPrefix: String
        repeat { cidPrefix = "cid:pmt-enex-" + UUID().uuidString + "-" } while note.content.contains(cidPrefix)
        for (offset, node) in nodes.enumerated() {
            try ConversionExecution.check()
            guard budget.resources > 0 else { throw ImportFailure("the ENEX exceeds its total resource count limit") }
            budget.resources -= 1
            guard let dataNode = try ENEXReader.single("data", in: node), let rawMIME = try ENEXReader.field("mime", in: node) else {
                throw ImportFailure("an ENEX resource has no unique data and MIME fields")
            }
            let data = try decoded(dataNode)
            try budget.consume(data.count)
            let mime = canonicalMIME(rawMIME)
            guard mime.utf8.count <= 256, mime.range(of: #"^[a-z0-9][a-z0-9!#$&^_.+\-]*/[a-z0-9][a-z0-9!#$&^_.+\-]*$"#, options: .regularExpression) != nil else {
                throw ImportFailure("an ENEX resource MIME type is invalid")
            }
            let attributes = try ENEXReader.single("resource-attributes", in: node)
            let name = try attributes.flatMap { try ENEXReader.field("file-name", in: $0) } ?? "Resource \(offset + 1)"
            guard name.utf8.count <= 4096 else { throw ImportFailure("an ENEX resource filename exceeds its display limit") }
            let display = name.components(separatedBy: .controlCharacters).joined(separator: " ")
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            // Gleiche Bytes werden nur einmal dekodiert. MD5 dient allein der
            // ENML-Zuordnung; die Wiederverwendung prüft den stärkeren SHA-256.
            let key = mime + "/" + fingerprint
            let type: (fileExtension: String, image: Bool)
            if let known = budget.inspectedTypes[key] { type = known }
            else {
                type = try inspectedType(data, mime: mime, budget: &budget)
                budget.inspectedTypes[key] = type
            }
            if type.fileExtension == "bin", mime != "application/octet-stream" {
                warnings.append(.init(code: "enex.resourceKeptAsBinary", message: "An ENEX resource type was retained as a binary attachment rather than rendered or opened as active content.", kind: .information))
            }
            let hash = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            // Exportnamen bleiben Beschriftungen. Ausschließlich Ordinal und
            // geprüfter Typ bestimmen den tatsächlichen Pfad.
            let stem = String(format: "resource-%06d", offset + 1)
            let path = "attachments/" + stem + "." + type.fileExtension
            try data.write(to: context.stagedOutputDirectory.appendingPathComponent(path), options: .withoutOverwriting)
            paths.append(path)
            records.append(.init(index: offset + 1, mime: mime, hash: hash, data: data, displayName: display,
                path: path, image: type.image, cid: cidPrefix + String(offset + 1)))
            appendix += "- [" + MarkdownEscaping.inlineLiteral(display) + "](" + path + ")\n\n"
            appendix += "MD5: `" + hash + "`\n\n"
            appendix += try ENEXAdapter.metadataTable(node, excluding: ["data", "alternate-data", "recognition"])
            if let alternate = try ENEXReader.single("alternate-data", in: node) {
                let bytes = try decoded(alternate)
                try budget.consume(bytes.count)
                let alternatePath = "attachments/" + stem + "-alternate.bin"
                try bytes.write(to: context.stagedOutputDirectory.appendingPathComponent(alternatePath), options: .withoutOverwriting)
                paths.append(alternatePath)
                appendix += "- [Alternate resource data](" + alternatePath + ")\n\n"
            }
            if let recognition = try ENEXReader.field("recognition", in: node) {
                try budget.consume(recognition.utf8.count)
                let recognitionPath = "attachments/" + stem + "-recognition.txt"
                try Data(recognition.utf8).write(to: context.stagedOutputDirectory.appendingPathComponent(recognitionPath), options: .withoutOverwriting)
                paths.append(recognitionPath)
                appendix += "- [Recognition source text](" + recognitionPath + ")\n\n"
            }
            guard appendix.utf8.count <= CollectionLimits.maximumDocumentBytes else { throw ImportFailure("ENEX resource metadata output exceeds its size limit") }
        }
        return .init(records: records, assetPaths: paths, appendix: appendix, warnings: warnings)
    }

    func media(_ node: ImportXML) -> (html: String, warning: ConversionWarning?) {
        let hash = (node.attribute("hash") ?? "").lowercased()
        let mime = Self.canonicalMIME(node.attribute("type") ?? "")
        let label = node.attribute("alt") ?? ""
        let candidates = byHash[hash] ?? []
        let matching = candidates.filter { $0.mime == mime }
        let code: String
        if candidates.isEmpty { code = "enex.resourceMissing" }
        else if matching.isEmpty { code = "enex.resourceTypeMismatch" }
        else if !matching.dropFirst().allSatisfy({ $0.data == matching[0].data }) { code = "enex.resourceHashAmbiguous" }
        else {
            let resource = matching[0]
            if resource.image {
                return ("<img src=\"" + resource.cid + "\" alt=\"" + ENMLConverter.escaped(label.isEmpty ? resource.displayName : label) + "\">", nil)
            }
            let text = label.isEmpty ? resource.displayName : label
            return ("<a href=\"" + resource.path + "\">" + ENMLConverter.escaped(text) + "</a>", nil)
        }
        let text = ["Resource", mime, hash, label].filter { !$0.isEmpty }.joined(separator: " ")
        return ("<span>" + ENMLConverter.escaped("[" + text + "]") + "</span>",
            .init(code: code, message: "An ENEX media reference has no unique matching resource and was retained as a placeholder.", kind: .contentLoss, omittedCount: 1))
    }

    static func canonicalMIME(_ raw: String) -> String {
        switch raw.lowercased() {
        case "image/jpg": "image/jpeg"
        case "image/x-ms-bmp": "image/bmp"
        default: raw.lowercased()
        }
    }
    static func decoded(_ node: ImportXML) throws -> Data {
        guard node.children.isEmpty, (node.attribute("encoding") ?? "base64") == "base64" else { throw ImportFailure("an ENEX resource encoding is unsupported") }
        let text = node.text
        var compact = [UInt8]()
        for (index, byte) in text.utf8.enumerated() {
            if index % 4096 == 0 { try ConversionExecution.check() }
            if [9, 10, 13, 32].contains(byte) { continue }
            guard (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [43, 47, 61].contains(byte) else {
                throw ImportFailure("an ENEX resource contains invalid Base64 characters")
            }
            compact.append(byte)
            guard compact.count <= maximumResourceBytes * 4 / 3 + 4 else { throw ImportFailure("an ENEX resource exceeds its decoded size limit") }
        }
        guard let data = Data(base64Encoded: Data(compact)), data.count <= maximumResourceBytes,
              data.base64EncodedData() == Data(compact) else { throw ImportFailure("an ENEX resource contains invalid or noncanonical Base64") }
        return data
    }

    private static func inspectedType(_ data: Data, mime: String, budget: inout Budget) throws -> (fileExtension: String, image: Bool) {
        let raster: [String: String] = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/tiff": "tiff", "image/webp": "webp", "image/bmp": "bmp", "image/heic": "heic"]
        if let expected = raster[mime] {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source) as String?, let format = ImageFileFormat(typeIdentifier: identifier), format.fileExtension == expected else {
                throw ImportFailure("an ENEX image resource does not match its declared type")
            }
            let count = CGImageSourceGetCount(source)
            guard count > 0, count <= ImageImportLimits.maximumFrames else { throw ImportFailure("an ENEX image resource exceeds its frame limit") }
            for index in 0..<count {
                try ConversionExecution.check()
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 64_000_000 / height else { throw ImportFailure("an ENEX image resource exceeds its pixel limit") }
                guard width * height <= budget.pixels else { throw ImportFailure("the ENEX image resources exceed their total pixel budget") }
                budget.pixels -= width * height
            }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), image.dataProvider?.data != nil else {
                throw ImportFailure("an ENEX image resource cannot be decoded")
            }
            return count == 1 ? (expected, true) : ("bin", false)
        }
        if mime == "application/pdf" {
            guard data.starts(with: Data("%PDF-".utf8)), let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider), document.numberOfPages > 0 || document.isEncrypted else {
                throw ImportFailure("an ENEX PDF attachment does not match its declared type")
            }
            return ("pdf", false)
        }
        if mime == "text/plain", String(data: data, encoding: .utf8) != nil, !data.contains(0) { return ("txt", false) }
        return ("bin", false)
    }
}
