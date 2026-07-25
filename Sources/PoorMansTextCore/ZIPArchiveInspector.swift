import Foundation
import zlib

struct WordProcessingPackageInspection {
    let format: InputFormat
    let containsComments: Bool
    let containsTrackedChanges: Bool
    let unsafeImageReferences: [String]

    var warnings: [ConversionWarning] {
        var result = [ConversionWarning]()
        if containsComments {
            result.append(.wordProcessingCommentsNotPreserved)
        }
        if containsTrackedChanges {
            result.append(
                format == .docx
                    ? .wordProcessingChangesAccepted
                    : .openDocumentChangesNotPreserved
            )
        }
        return result
    }
}

/// Liest nur das ZIP-Verzeichnis und wenige XML-Dateien. So wird ein Paket
/// inhaltlich erkannt und auf Traversal, Symlinks und ZIP-Bomben geprüft, bevor
/// Pandoc es in einem isolierten Arbeitsordner öffnet.
enum ZIPArchiveInspector {
    static func inspectWordProcessingPackage(
        at inputURL: URL
    ) throws -> WordProcessingPackageInspection? {
        let archive = try Archive(url: inputURL)
        let entryNames = Set(archive.entries.map(\.name))

        if entryNames.contains("[Content_Types].xml"),
           entryNames.contains("word/document.xml") {
            let documentXML = try archive.string(named: "word/document.xml")
            let commentsXML = entryNames.contains("word/comments.xml")
                ? try archive.string(named: "word/comments.xml")
                : ""
            let comments = documentXML.contains("<w:commentRangeStart")
                || commentsXML.contains("<w:comment ")
            let changes = [
                "<w:ins", "<w:del", "<w:moveFrom", "<w:moveTo",
            ].contains { documentXML.contains($0) }
            let externalImages = try archive.entries
                .filter { $0.name.hasSuffix(".rels") && !$0.isDirectory }
                .flatMap { entry -> [String] in
                    let xml = try archive.data(for: entry)
                    return try ExternalImageRelationshipParser.targets(in: xml)
                }

            return WordProcessingPackageInspection(
                format: .docx,
                containsComments: comments,
                containsTrackedChanges: changes,
                unsafeImageReferences: externalImages.sorted()
            )
        }

        if entryNames.contains("mimetype"),
           entryNames.contains("content.xml"),
           try archive.string(named: "mimetype")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == "application/vnd.oasis.opendocument.text" {
            let contentXML = try archive.data(named: "content.xml")
            let content = String(decoding: contentXML, as: UTF8.self)
            let parsed = try ODTContentParser.inspect(contentXML)
            return WordProcessingPackageInspection(
                format: .odt,
                containsComments: content.contains("<office:annotation"),
                containsTrackedChanges: content.contains("<text:tracked-changes"),
                unsafeImageReferences: parsed.externalImageReferences.sorted()
            )
        }

        return nil
    }

    static func looksLikeZIP(at inputURL: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: inputURL)
        defer {
            try? handle.close()
        }
        let signature = [UInt8](try handle.read(upToCount: 4) ?? Data())
        return signature == [0x50, 0x4B, 0x03, 0x04]
            || signature == [0x50, 0x4B, 0x05, 0x06]
            || signature == [0x50, 0x4B, 0x07, 0x08]
    }

    private struct Archive {
        let data: Data
        let entries: [Entry]

        init(url: URL) throws {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw ArchiveError("the package is not a regular file")
            }
            guard let fileSize = values.fileSize, fileSize <= Limits.maximumArchiveSize else {
                throw ArchiveError("the package exceeds the supported archive-size limit")
            }

            data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let endOffset = Self.endOfCentralDirectory(in: data) else {
                throw ArchiveError("the ZIP central directory is missing")
            }
            guard data.uint16(at: endOffset + 4) == 0,
                  data.uint16(at: endOffset + 6) == 0 else {
                throw ArchiveError("multi-disk ZIP packages are not supported")
            }

            let entryCount = Int(data.uint16(at: endOffset + 10))
            let centralSize = Int(data.uint32(at: endOffset + 12))
            let centralOffset = Int(data.uint32(at: endOffset + 16))
            guard entryCount != Int(UInt16.max),
                  centralSize != Int(UInt32.max),
                  centralOffset != Int(UInt32.max) else {
                throw ArchiveError("ZIP64 packages are not supported")
            }
            guard entryCount <= Limits.maximumEntryCount else {
                throw ArchiveError("the package contains too many ZIP entries")
            }
            guard centralOffset >= 0,
                  centralSize >= 0,
                  centralOffset + centralSize <= endOffset else {
                throw ArchiveError("the ZIP central directory is invalid")
            }

            var parsedEntries = [Entry]()
            parsedEntries.reserveCapacity(entryCount)
            var names = Set<String>()
            var totalUncompressedSize = 0
            var offset = centralOffset

            for _ in 0..<entryCount {
                guard data.uint32(at: offset) == 0x02014B50 else {
                    throw ArchiveError("the ZIP central directory contains an invalid entry")
                }
                let flags = data.uint16(at: offset + 8)
                let method = data.uint16(at: offset + 10)
                let crc = data.uint32(at: offset + 16)
                let compressedSize = Int(data.uint32(at: offset + 20))
                let uncompressedSize = Int(data.uint32(at: offset + 24))
                let nameLength = Int(data.uint16(at: offset + 28))
                let extraLength = Int(data.uint16(at: offset + 30))
                let commentLength = Int(data.uint16(at: offset + 32))
                let externalAttributes = data.uint32(at: offset + 38)
                let localHeaderOffset = Int(data.uint32(at: offset + 42))
                let entryEnd = offset + 46 + nameLength + extraLength + commentLength

                guard compressedSize != Int(UInt32.max),
                      uncompressedSize != Int(UInt32.max),
                      localHeaderOffset != Int(UInt32.max) else {
                    throw ArchiveError("ZIP64 entries are not supported")
                }
                guard entryEnd <= centralOffset + centralSize,
                      nameLength > 0 else {
                    throw ArchiveError("a ZIP entry has an invalid length")
                }
                guard flags & 0x0001 == 0 else {
                    throw ArchiveError("encrypted ZIP entries are not supported")
                }
                guard method == 0 || method == 8 else {
                    throw ArchiveError("a ZIP entry uses an unsupported compression method")
                }

                let rawName = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
                guard !rawName.contains(0),
                      let name = String(data: rawName, encoding: .utf8)
                        ?? String(data: rawName, encoding: .isoLatin1) else {
                    throw ArchiveError("a ZIP entry name is not readable")
                }
                try Self.validateEntryName(name)
                guard names.insert(name).inserted else {
                    throw ArchiveError("the ZIP package contains a duplicate entry: \(name)")
                }

                let hostSystem = data[offset + 5]
                let unixMode = externalAttributes >> 16
                if hostSystem == 3, unixMode & 0xF000 == 0xA000 {
                    throw ArchiveError("symbolic links are not allowed in document packages")
                }

                totalUncompressedSize += uncompressedSize
                guard totalUncompressedSize <= Limits.maximumUncompressedSize else {
                    throw ArchiveError("the ZIP package expands beyond the supported size limit")
                }

                parsedEntries.append(
                    Entry(
                        name: name,
                        rawName: rawName,
                        flags: flags,
                        method: method,
                        crc: crc,
                        compressedSize: compressedSize,
                        uncompressedSize: uncompressedSize,
                        localHeaderOffset: localHeaderOffset,
                        isDirectory: name.hasSuffix("/")
                    )
                )
                offset = entryEnd
            }

            guard offset == centralOffset + centralSize else {
                throw ArchiveError("the ZIP central directory size is inconsistent")
            }
            entries = parsedEntries
        }

        func string(named name: String) throws -> String {
            String(decoding: try data(named: name), as: UTF8.self)
        }

        func data(named name: String) throws -> Data {
            guard let entry = entries.first(where: { $0.name == name }) else {
                throw ArchiveError("the document package is missing \(name)")
            }
            return try data(for: entry)
        }

        func data(for entry: Entry) throws -> Data {
            guard entry.uncompressedSize <= Limits.maximumMetadataEntrySize else {
                throw ArchiveError("the package metadata entry \(entry.name) is too large")
            }
            let offset = entry.localHeaderOffset
            guard data.uint32(at: offset) == 0x04034B50 else {
                throw ArchiveError("the local ZIP header for \(entry.name) is invalid")
            }
            let localFlags = data.uint16(at: offset + 6)
            let localMethod = data.uint16(at: offset + 8)
            let nameLength = Int(data.uint16(at: offset + 26))
            let extraLength = Int(data.uint16(at: offset + 28))
            let contentStart = offset + 30 + nameLength + extraLength
            let contentEnd = contentStart + entry.compressedSize
            guard localFlags == entry.flags,
                  localMethod == entry.method,
                  contentEnd <= data.count,
                  data.subdata(in: (offset + 30)..<(offset + 30 + nameLength))
                    == entry.rawName else {
                throw ArchiveError("the local ZIP entry for \(entry.name) is inconsistent")
            }

            let result: Data
            switch entry.method {
            case 0:
                result = data.subdata(in: contentStart..<contentEnd)
            case 8:
                result = try inflate(
                    data.subdata(in: contentStart..<contentEnd),
                    expectedSize: entry.uncompressedSize,
                    entryName: entry.name
                )
            default:
                throw ArchiveError("the ZIP compression method is unsupported")
            }

            guard result.count == entry.uncompressedSize else {
                throw ArchiveError("the uncompressed size of \(entry.name) is inconsistent")
            }
            let checksum = result.withUnsafeBytes { buffer -> UInt32 in
                guard let baseAddress = buffer.bindMemory(to: Bytef.self).baseAddress else {
                    return UInt32(zlib.crc32(0, nil, 0))
                }
                return UInt32(zlib.crc32(0, baseAddress, uInt(buffer.count)))
            }
            guard checksum == entry.crc else {
                throw ArchiveError("the checksum of \(entry.name) is invalid")
            }
            return result
        }

        private static func endOfCentralDirectory(in data: Data) -> Int? {
            guard data.count >= 22 else {
                return nil
            }
            let lowerBound = max(0, data.count - 65_557)
            for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
                if data.uint32(at: offset) == 0x06054B50 {
                    let commentLength = Int(data.uint16(at: offset + 20))
                    if offset + 22 + commentLength == data.count {
                        return offset
                    }
                }
            }
            return nil
        }

        private static func validateEntryName(_ name: String) throws {
            let logicalName = name.hasSuffix("/") ? String(name.dropLast()) : name
            let components = logicalName.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard !logicalName.isEmpty,
                  !name.hasPrefix("/"),
                  !name.contains("\\"),
                  !name.contains("\0"),
                  !components.contains(where: {
                      $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(":")
                  }) else {
                throw ArchiveError("the ZIP package contains an unsafe entry path")
            }
        }
    }

    private struct Entry {
        let name: String
        let rawName: Data
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let isDirectory: Bool
    }

    private enum Limits {
        static let maximumArchiveSize = 1_073_741_824
        static let maximumEntryCount = 10_000
        static let maximumUncompressedSize = 1_073_741_824
        static let maximumMetadataEntrySize = 16_777_216
    }

    private static func inflate(
        _ compressed: Data,
        expectedSize: Int,
        entryName: String
    ) throws -> Data {
        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw ArchiveError("zlib could not initialize for \(entryName)")
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data(count: max(expectedSize, 1))
        let status = compressed.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer -> Int32 in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(inputBuffer.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END,
              Int(stream.total_out) == expectedSize else {
            throw ArchiveError("the compressed data for \(entryName) is invalid")
        }
        output.count = expectedSize
        return output
    }

    private struct ArchiveError: LocalizedError {
        let reason: String

        init(_ reason: String) {
            self.reason = reason
        }

        var errorDescription: String? {
            reason
        }
    }
}

private enum ExternalImageRelationshipParser {
    static func targets(in xml: Data) throws -> [String] {
        let delegate = RelationshipDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return delegate.targets
    }

    private final class RelationshipDelegate: NSObject, XMLParserDelegate {
        var targets = [String]()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "Relationship",
                  attributeDict["TargetMode"]?.lowercased() == "external",
                  attributeDict["Type"]?.lowercased().hasSuffix("/image") == true,
                  let target = attributeDict["Target"] else {
                return
            }
            targets.append(target)
        }
    }
}

private struct ODTContentInspection {
    let externalImageReferences: [String]
}

private enum ODTContentParser {
    static func inspect(_ xml: Data) throws -> ODTContentInspection {
        let delegate = ContentDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return ODTContentInspection(externalImageReferences: delegate.externalImages)
    }

    private final class ContentDelegate: NSObject, XMLParserDelegate {
        var externalImages = [String]()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "draw:image",
                  let reference = attributeDict["xlink:href"],
                  isUnsafe(reference) else {
                return
            }
            externalImages.append(reference)
        }

        private func isUnsafe(_ reference: String) -> Bool {
            guard !reference.isEmpty else {
                return true
            }
            if let url = URL(string: reference), url.scheme != nil {
                return true
            }
            let components = NSString(string: reference).pathComponents
            return reference.hasPrefix("/")
                || reference.contains("\\")
                || components.contains("..")
        }
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            return 0
        }
        return UInt16(self[offset])
            | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            return 0
        }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
