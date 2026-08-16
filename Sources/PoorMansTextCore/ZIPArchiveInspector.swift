import Foundation
import zlib

enum WordProcessingPackageKind {
    case document
    case macroEnabledDocument
    case template
    case macroEnabledTemplate

    var containsMacros: Bool {
        self == .macroEnabledDocument || self == .macroEnabledTemplate
    }

    var isTemplate: Bool {
        self == .template || self == .macroEnabledTemplate
    }
}

struct WordProcessingPackageInspection {
    let format: InputFormat
    let packageKind: WordProcessingPackageKind?
    let containsComments: Bool
    let containsTrackedChanges: Bool
    let unsafeImageReferences: [String]

    var warnings: [ConversionWarning] {
        var result = [ConversionWarning]()
        if packageKind?.containsMacros == true {
            result.append(.wordProcessingMacrosNotPreserved)
        }
        if packageKind?.isTemplate == true {
            result.append(.wordProcessingTemplateSemanticsNotPreserved)
        }
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

struct ZIPPackageContents {
    let entryNames: Set<String>
    let entries: [String: Data]
}

/// Liest nur das ZIP-Verzeichnis und wenige XML-Dateien. So wird ein Paket
/// inhaltlich erkannt und auf Traversal, Symlinks und ZIP-Bomben geprüft, bevor
/// Pandoc es in einem isolierten Arbeitsordner öffnet.
enum ZIPArchiveInspector {
    /// Stellt ausgewählte Paketdateien für andere native Adapter bereit. Schon
    /// das Öffnen des Archivs prüft Namen, Größenbudgets, Verschlüsselung,
    /// Kompressionsarten und Symlinks; die Konvertierung ruft diese Funktion auf
    /// einer zuvor vollständig verifizierten Arbeitskopie auf.
    static func packageContents(
        at inputURL: URL,
        entryNames requestedNames: [String]
    ) throws -> ZIPPackageContents {
        let archive = try Archive(url: inputURL)
        let names = Set(archive.entries.map(\.name))
        var entries = [String: Data]()
        for name in requestedNames where names.contains(name) {
            entries[name] = try archive.data(named: name)
        }
        return ZIPPackageContents(entryNames: names, entries: entries)
    }

    static func inspectWordProcessingPackage(
        at inputURL: URL
    ) throws -> WordProcessingPackageInspection? {
        let archive = try Archive(url: inputURL)
        let entryNames = Set(archive.entries.map(\.name))

        if entryNames.contains("[Content_Types].xml"),
           entryNames.contains("word/document.xml") {
            let packageKind = try WordprocessingContentTypesParser.packageKind(
                in: try archive.data(named: "[Content_Types].xml")
            )
            let document = try WordprocessingContentParser.inspect(
                try archive.data(named: "word/document.xml")
            )
            guard document.hasDocumentRoot else {
                throw ArchiveError("word/document.xml has no valid WordprocessingML document root")
            }
            let commentDefinitions = entryNames.contains("word/comments.xml")
                ? try WordprocessingContentParser.inspect(
                    try archive.data(named: "word/comments.xml")
                ).containsCommentDefinitions
                : false
            let comments = document.containsCommentAnchors || commentDefinitions
            let changes = document.containsTrackedChanges
            let externalImages = try archive.entries
                .filter { $0.name.hasSuffix(".rels") && !$0.isDirectory }
                .flatMap { entry -> [String] in
                    let xml = try archive.data(for: entry)
                    return try ExternalImageRelationshipParser.targets(in: xml)
                }

            return WordProcessingPackageInspection(
                format: .docx,
                packageKind: packageKind,
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
            let parsed = try ODTContentParser.inspect(try archive.data(named: "content.xml"))
            return WordProcessingPackageInspection(
                format: .odt,
                packageKind: nil,
                containsComments: parsed.containsAnnotations,
                containsTrackedChanges: parsed.containsTrackedChanges,
                unsafeImageReferences: parsed.externalImageReferences.sorted()
            )
        }

        return nil
    }

    /// Kopiert das Paket unveränderlich in den privaten Arbeitsbereich und prüft
    /// genau diese Kopie vollständig durch.
    ///
    /// Zwei Gründe für die Kopie: Der geprüfte Originalpfad kann zwischen Prüfung
    /// und Pandoc-Lauf ausgetauscht werden (Time-of-check-to-time-of-use), und nur
    /// eine Kopie im eigenen Arbeitsordner bleibt während der Umwandlung stabil.
    /// Die Prüfung entpackt jeden Eintrag streamend und vergleicht dabei
    /// tatsächliche Größe und Prüfsumme mit den Angaben im ZIP-Verzeichnis — ohne
    /// das zählt das Entpackbudget nur die *deklarierten* Größen, und ein
    /// präparierter Medieneintrag könnte beim Pandoc-Lauf beliebig groß werden.
    static func stageVerifiedPackage(
        from inputURL: URL,
        into directory: URL,
        named name: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let values = try inputURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ArchiveError("the package is not a regular file")
        }
        guard let fileSize = values.fileSize, fileSize <= Limits.maximumArchiveSize else {
            throw ArchiveError("the package exceeds the supported archive-size limit")
        }

        let stagedURL = directory.appendingPathComponent(name)
        do {
            try fileManager.copyItem(at: inputURL, to: stagedURL)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        let archive = try Archive(url: stagedURL)
        try archive.verifyEntryContents()
        return stagedURL
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
                // Beim Entpacken zählt der Name, den das Dateisystem sieht: APFS
                // ist standardmäßig nicht zwischen Groß- und Kleinschreibung
                // unterscheidend, deshalb würden `word/media/a.png` und
                // `word/media/A.png` dieselbe Datei sein und ein Eintrag den
                // anderen still überschreiben. Der abschließende Slash fällt
                // dabei weg, damit auch der Verzeichniseintrag `x/` mit der
                // Datei `x` kollidiert. Unicode-Normalisierung (etwa "ä" als ein
                // Zeichen gegen "a" plus Trema) fängt der Swift-Vergleich von
                // Zeichenketten bereits selbst ab.
                let collisionKey = Self.logicalName(of: name).folding(
                    options: [.caseInsensitive],
                    locale: nil
                )
                guard names.insert(collisionKey).inserted else {
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
            let contentRange = try contentRange(for: entry)

            let result: Data
            switch entry.method {
            case 0:
                result = data.subdata(in: contentRange)
            case 8:
                result = try inflate(
                    data.subdata(in: contentRange),
                    expectedSize: entry.uncompressedSize,
                    entryName: entry.name
                )
            default:
                throw ArchiveError("the ZIP compression method is unsupported")
            }

            guard result.count == entry.uncompressedSize else {
                throw ArchiveError("the uncompressed size of \(entry.name) is inconsistent")
            }
            try ZIPArchiveInspector.verifyChecksum(
                of: result,
                expected: entry.crc,
                entryName: entry.name
            )
            return result
        }

        /// Prüft JEDEN Eintrag gegen seinen Verzeichniseintrag: tatsächliche
        /// entpackte Größe und CRC-32. Erst danach ist das in `init` geprüfte
        /// Entpackbudget wirklich belastbar, denn dort werden nur die vom Archiv
        /// selbst deklarierten Größen addiert.
        ///
        /// Der Inhalt wird dabei absichtlich nicht behalten: Jeder Eintrag läuft
        /// in Blöcken durch einen festen kleinen Puffer, und sobald mehr Bytes
        /// entstehen als deklariert, bricht die Prüfung sofort ab. Ein präparierter
        /// Eintrag kann so weder Speicher noch Zeit über sein deklariertes Maß
        /// hinaus verbrauchen.
        ///
        /// `data[contentRange]` liefert einen Ausschnitt auf denselben Speicher.
        /// `subdata(in:)` würde stattdessen jeden Eintrag zusätzlich kopieren —
        /// bei einem zulässigen Archiv von bis zu 1 GiB wäre die angeblich
        /// streamende Prüfung dann der größte Speicherverbraucher überhaupt.
        func verifyEntryContents() throws {
            for entry in entries where !entry.isDirectory {
                let contentRange = try contentRange(for: entry)
                switch entry.method {
                case 0:
                    guard entry.compressedSize == entry.uncompressedSize else {
                        throw ArchiveError(
                            "the stored size of \(entry.name) does not match its declared size"
                        )
                    }
                    try ZIPArchiveInspector.verifyChecksum(
                        of: data[contentRange],
                        expected: entry.crc,
                        entryName: entry.name
                    )
                case 8:
                    try ZIPArchiveInspector.verifyDeflated(
                        data[contentRange],
                        expectedSize: entry.uncompressedSize,
                        expectedChecksum: entry.crc,
                        entryName: entry.name
                    )
                default:
                    throw ArchiveError("the ZIP compression method is unsupported")
                }
            }
        }

        /// Der Bytebereich des Eintragsinhalts, nachdem der lokale Header gegen
        /// den Verzeichniseintrag geprüft wurde.
        private func contentRange(for entry: Entry) throws -> Range<Int> {
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
                  entry.compressedSize >= 0,
                  contentEnd <= data.count,
                  data.subdata(in: (offset + 30)..<(offset + 30 + nameLength))
                    == entry.rawName else {
                throw ArchiveError("the local ZIP entry for \(entry.name) is inconsistent")
            }
            return contentStart..<contentEnd
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

        /// Der Name ohne abschließenden Slash: ZIP markiert Verzeichnisse so,
        /// gemeint ist aber derselbe Pfad wie bei einer gleichnamigen Datei.
        private static func logicalName(of name: String) -> String {
            name.hasSuffix("/") ? String(name.dropLast()) : name
        }

        private static func validateEntryName(_ name: String) throws {
            let logicalName = Self.logicalName(of: name)
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

    /// Entpackt einen Deflate-Eintrag blockweise, ohne das Ergebnis zu behalten,
    /// und vergleicht Größe und CRC-32 mit dem Verzeichniseintrag. Sobald mehr
    /// Bytes entstehen als deklariert, endet der Lauf sofort — genau das ist der
    /// Schutz gegen einen klein deklarierten, in Wahrheit riesigen Eintrag.
    private static func verifyDeflated(
        _ compressed: Data,
        expectedSize: Int,
        expectedChecksum: UInt32,
        entryName: String
    ) throws {
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

        var buffer = [UInt8](repeating: 0, count: 65_536)
        var produced = 0
        var checksum = zlib.crc32(0, nil, 0)
        var status = Z_OK

        compressed.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: input.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(input.count)

            while status == Z_OK {
                status = buffer.withUnsafeMutableBufferPointer { output -> Int32 in
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    let step = zlib.inflate(&stream, Z_NO_FLUSH)
                    let chunk = output.count - Int(stream.avail_out)
                    if chunk > 0, let baseAddress = output.baseAddress {
                        checksum = zlib.crc32(checksum, baseAddress, uInt(chunk))
                        produced += chunk
                    }
                    return step
                }
                if produced > expectedSize {
                    return
                }
            }
        }

        guard produced <= expectedSize else {
            throw ArchiveError("\(entryName) expands beyond the size declared in the ZIP directory")
        }
        guard status == Z_STREAM_END, produced == expectedSize else {
            throw ArchiveError("the compressed data for \(entryName) is invalid")
        }
        guard UInt32(truncatingIfNeeded: checksum) == expectedChecksum else {
            throw ArchiveError("the checksum of \(entryName) is invalid")
        }
    }

    private static func verifyChecksum(
        of content: Data,
        expected: UInt32,
        entryName: String
    ) throws {
        let checksum = content.withUnsafeBytes { buffer -> UInt32 in
            guard let baseAddress = buffer.bindMemory(to: Bytef.self).baseAddress else {
                return UInt32(zlib.crc32(0, nil, 0))
            }
            return UInt32(zlib.crc32(0, baseAddress, uInt(buffer.count)))
        }
        guard checksum == expected else {
            throw ArchiveError("the checksum of \(entryName) is invalid")
        }
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

/// Startet einen XML-Lauf mit Namensraumverarbeitung.
///
/// Ohne sie liefert `XMLParser` den Elementnamen samt Präfix (`r:Relationship`),
/// und ein Paket mit einem anderen — aber völlig gültigen — Präfix rutscht an
/// jeder Namensprüfung vorbei. Mit ihr ist `elementName` der lokale Name.
///
/// Attributnamen behalten ihr Präfix auch dann. Damit ein Delegate es auflösen
/// kann, meldet `shouldReportNamespacePrefixes` zusätzlich jede
/// Präfix-Deklaration; ohne dieses Flag ruft `XMLParser` die zugehörigen
/// Delegate-Methoden gar nicht erst auf. In die Attributliste geraten die
/// `xmlns`-Deklarationen dadurch nicht.
private func parseXML(_ xml: Data, with delegate: XMLParserDelegate) throws {
    let parser = XMLParser(data: xml)
    parser.delegate = delegate
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = true
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else {
        throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
    }
}

/// Der Wert eines laut OPC unpräfigierten Attributs.
///
/// Der XML-Standard legt unpräfigierte Attribute in keinen Namensraum. Deshalb
/// darf ein fremdes `foo:PartName` oder `foo:Target` nicht allein wegen seines
/// gleichen Suffixes als OPC-Attribut gelten.
private func attributeValue(
    localName: String,
    in attributes: [String: String]
) -> String? {
    attributes[localName]
}

/// Die Namensräume, deren Elemente die Paketprüfung auswerten darf.
private enum InspectedNamespaces {
    static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    static let drawing = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
    static let xlink = "http://www.w3.org/1999/xlink"
    static let wordprocessing: Set<String> = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main",
    ]
}

private enum ExternalImageRelationshipParser {
    static func targets(in xml: Data) throws -> [String] {
        let delegate = RelationshipDelegate()
        try parseXML(xml, with: delegate)
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
                  attributeValue(localName: "TargetMode", in: attributeDict)?.lowercased()
                    == "external",
                  attributeValue(localName: "Type", in: attributeDict)?
                    .lowercased().hasSuffix("/image") == true,
                  let target = attributeValue(localName: "Target", in: attributeDict) else {
                return
            }
            targets.append(target)
        }
    }
}

/// Liest den Typ des Word-Hauptteils aus dem dafür verbindlichen
/// `[Content_Types].xml`. So werden DOCM und DOTX nicht still wie ein normales
/// DOCX behandelt, und ein beliebiges ZIP mit `word/document.xml` reicht nicht
/// mehr als Formaterkennung aus.
private enum WordprocessingContentTypesParser {
    static func packageKind(in xml: Data) throws -> WordProcessingPackageKind {
        let delegate = ContentTypesDelegate()
        try parseXML(xml, with: delegate)
        guard delegate.hasValidRoot else {
            throw ContentTypeError("[Content_Types].xml has no valid Types root")
        }
        guard delegate.mainContentTypes.count == 1,
              let contentType = delegate.mainContentTypes.first else {
            throw ContentTypeError(
                "[Content_Types].xml must declare exactly one content type for word/document.xml"
            )
        }

        return switch contentType.lowercased() {
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml":
            .document
        case "application/vnd.ms-word.document.macroenabled.main+xml":
            .macroEnabledDocument
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml":
            .template
        case "application/vnd.ms-word.template.macroenabledtemplate.main+xml":
            .macroEnabledTemplate
        default:
            throw ContentTypeError(
                "word/document.xml has an unsupported main content type: \(contentType)"
            )
        }
    }

    private final class ContentTypesDelegate: NSObject, XMLParserDelegate {
        var hasValidRoot = false
        var mainContentTypes = Set<String>()
        private var sawRoot = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if !sawRoot {
                sawRoot = true
                hasValidRoot = elementName == "Types"
                    && namespaceURI == "http://schemas.openxmlformats.org/package/2006/content-types"
            }
            guard namespaceURI == "http://schemas.openxmlformats.org/package/2006/content-types",
                  elementName == "Override",
                  let partName = attributeValue(localName: "PartName", in: attributeDict),
                  "/" + partName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    == "/word/document.xml",
                  let contentType = attributeValue(
                    localName: "ContentType",
                    in: attributeDict
                  ) else {
                return
            }
            mainContentTypes.insert(contentType)
        }
    }

    private struct ContentTypeError: LocalizedError {
        let reason: String

        init(_ reason: String) {
            self.reason = reason
        }

        var errorDescription: String? { reason }
    }
}

private struct WordprocessingContentInspection {
    let rootElementName: String?
    let rootNamespaceURI: String?
    let containsCommentAnchors: Bool
    let containsCommentDefinitions: Bool
    let containsTrackedChanges: Bool

    var hasDocumentRoot: Bool {
        guard rootElementName == "document", let rootNamespaceURI else {
            return false
        }
        return InspectedNamespaces.wordprocessing.contains(rootNamespaceURI)
    }
}

/// Zählt WordprocessingML-Elemente über ihren exakten lokalen Namen und ihren
/// Namensraum.
///
/// Eine Teilstringsuche nach `<w:ins` trifft auch den ganz gewöhnlichen
/// Feldcode `<w:instrText>`; ein Dokument mit Inhaltsverzeichnis oder Seitenzahl
/// bekäme dann die falsche Warnung, nachverfolgte Änderungen seien angenommen
/// worden. Und ein `ins`-Element aus einem fremden Namensraum — etwa aus
/// eingebettetem HTML — ist überhaupt keine nachverfolgte Änderung.
private enum WordprocessingContentParser {
    static func inspect(_ xml: Data) throws -> WordprocessingContentInspection {
        let delegate = ContentDelegate()
        try parseXML(xml, with: delegate)
        return WordprocessingContentInspection(
            rootElementName: delegate.rootElementName,
            rootNamespaceURI: delegate.rootNamespaceURI,
            containsCommentAnchors: delegate.containsCommentAnchors,
            containsCommentDefinitions: delegate.containsCommentDefinitions,
            containsTrackedChanges: delegate.containsTrackedChanges
        )
    }

    private final class ContentDelegate: NSObject, XMLParserDelegate {
        var containsCommentAnchors = false
        var containsCommentDefinitions = false
        var containsTrackedChanges = false
        var rootElementName: String?
        var rootNamespaceURI: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if rootElementName == nil {
                rootElementName = elementName
                rootNamespaceURI = namespaceURI
            }
            guard let namespaceURI,
                  InspectedNamespaces.wordprocessing.contains(namespaceURI) else {
                return
            }
            switch elementName {
            case "commentRangeStart":
                containsCommentAnchors = true
            case "comment":
                containsCommentDefinitions = true
            case "ins", "del", "moveFrom", "moveTo":
                containsTrackedChanges = true
            default:
                break
            }
        }
    }
}

private struct ODTContentInspection {
    let containsAnnotations: Bool
    let containsTrackedChanges: Bool
    let externalImageReferences: [String]
}

private enum ODTContentParser {
    static func inspect(_ xml: Data) throws -> ODTContentInspection {
        let delegate = ContentDelegate()
        try parseXML(xml, with: delegate)
        return ODTContentInspection(
            containsAnnotations: delegate.containsAnnotations,
            containsTrackedChanges: delegate.containsTrackedChanges,
            externalImageReferences: delegate.externalImages
        )
    }

    private final class ContentDelegate: NSObject, XMLParserDelegate {
        var containsAnnotations = false
        var containsTrackedChanges = false
        var externalImages = [String]()
        private let prefixes = NamespacePrefixTracker()

        func parser(
            _ parser: XMLParser,
            didStartMappingPrefix prefix: String,
            toURI namespaceURI: String
        ) {
            prefixes.startMapping(prefix: prefix, uri: namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            prefixes.endMapping(prefix: prefix)
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            // Jedes Element zählt nur in seinem ODF-Namensraum. Ein fremdes
            // `foo:image` oder `foo:annotation` ist kein ODF-Bild und keine
            // ODF-Notiz und darf deshalb keine Warnung oder Ablehnung auslösen.
            guard let namespaceURI else { return }
            switch (namespaceURI, elementName) {
            case (InspectedNamespaces.office, "annotation"):
                containsAnnotations = true
            case (InspectedNamespaces.text, "tracked-changes"):
                containsTrackedChanges = true
            case (InspectedNamespaces.drawing, "image"):
                guard let reference = prefixes.attributeValue(
                    localName: "href",
                    namespaceURI: InspectedNamespaces.xlink,
                    in: attributeDict
                ), isUnsafe(reference) else {
                    return
                }
                externalImages.append(reference)
            default:
                break
            }
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
