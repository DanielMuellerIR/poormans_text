import Compression
import Foundation

/// Baut ZIP-Pakete Byte für Byte, damit Tests auch Archive erzeugen können, die
/// über ihre eigenen Einträge lügen. Kein Werkzeug der Kommandozeile schreibt so
/// ein Archiv, deshalb entsteht es hier.
enum ZIPFixtureBuilder {
    struct Entry {
        let name: String
        let content: Data
        /// Weicht sie von der echten Größe ab, lügt das Archiv über den Eintrag.
        var declaredUncompressedSize: Int?
        /// Weicht sie von der echten CRC-32 ab, ist der Inhalt manipuliert.
        var declaredChecksum: UInt32?
        /// `true` legt den Eintrag unkomprimiert ab (ZIP-Methode 0).
        var isStored = false
        /// Rohe Namensbytes statt der UTF-8-Kodierung von `name`. Damit lassen
        /// sich Archive nachbauen, die ihren Namen NICHT in UTF-8 ablegen —
        /// etwa CP437, die Standardkodierung ohne General-Purpose-Bit 11.
        var rawNameBytes: Data?
        /// Erzwungene General-Purpose-Flags. Ohne Angabe setzt der Builder Bit
        /// 11 genau dann, wenn der Name nicht rein ASCII ist.
        var explicitFlags: UInt16?
    }

    enum BuilderError: Error {
        case compressionFailed(String)
    }

    /// Ein DOCX-ähnliches Paket: die beiden von der Erkennung verlangten
    /// Einträge plus ein Medieneintrag, über den der Test lügen lassen kann.
    static func wordProcessingPackage(
        mediaContent: Data = Data(repeating: 0x2E, count: 4096),
        declaredMediaSize: Int? = nil,
        declaredMediaChecksum: UInt32? = nil,
        mainContentType: String = docxMainContentType
    ) throws -> Data {
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>Fixture text</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let contentTypes = contentTypesXML(mainContentType: mainContentType)
        return try archive(entries: [
            Entry(name: "[Content_Types].xml", content: Data(contentTypes.utf8)),
            Entry(name: "word/document.xml", content: Data(documentXML.utf8)),
            Entry(
                name: "word/media/image1.bin",
                content: mediaContent,
                declaredUncompressedSize: declaredMediaSize,
                declaredChecksum: declaredMediaChecksum
            ),
        ])
    }

    /// Ein DOCX-Paket mit frei wählbarem `word/document.xml`, damit Tests
    /// Namensraum-Präfixe und Feldcodes durchspielen können.
    static func docxPackage(
        documentXML: String,
        relationshipsXML: String? = nil,
        mainContentType: String = docxMainContentType,
        contentTypesOverride: String? = nil
    ) throws -> Data {
        let contentTypes = contentTypesOverride
            ?? contentTypesXML(mainContentType: mainContentType)
        var entries = [
            Entry(name: "[Content_Types].xml", content: Data(contentTypes.utf8)),
            Entry(name: "word/document.xml", content: Data(documentXML.utf8)),
        ]
        if let relationshipsXML {
            entries.append(
                Entry(
                    name: "word/_rels/document.xml.rels",
                    content: Data(relationshipsXML.utf8)
                )
            )
        }
        return try archive(entries: entries)
    }

    static let docxMainContentType =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
    static let docmMainContentType =
        "application/vnd.ms-word.document.macroEnabled.main+xml"
    static let dotxMainContentType =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml"
    static let dotmMainContentType =
        "application/vnd.ms-word.template.macroEnabledTemplate.main+xml"

    private static func contentTypesXML(mainContentType: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Override PartName="/word/document.xml" ContentType="\(mainContentType)"/>
        </Types>
        """
    }

    /// Ein ODT-Paket mit frei wählbarem `content.xml`.
    static func odtPackage(contentXML: String) throws -> Data {
        try archive(entries: [
            Entry(
                name: "mimetype",
                content: Data("application/vnd.oasis.opendocument.text".utf8),
                isStored: true
            ),
            Entry(name: "content.xml", content: Data(contentXML.utf8)),
        ])
    }

    static func odsPackage(contentXML: String) throws -> Data {
        try archive(entries: [
            Entry(
                name: "mimetype",
                content: Data("application/vnd.oasis.opendocument.spreadsheet".utf8),
                isStored: true
            ),
            Entry(name: "content.xml", content: Data(contentXML.utf8)),
        ])
    }

    /// - Parameters:
    ///   - extraSheetDeclarations: zusätzliche `<sheet …/>`-Zeilen für
    ///     `xl/workbook.xml`, etwa ein Diagrammblatt.
    ///   - extraWorkbookRelationships: die passenden `<Relationship …/>`-Zeilen.
    ///   - extraEntries: weitere Paketdateien, etwa moderne Kommentare.
    static func xlsxPackage(
        firstSheetXML: String,
        secondSheetXML: String,
        secondSheetTargetMode: String? = nil,
        extraSheetDeclarations: String = "",
        extraWorkbookRelationships: String = "",
        extraEntries: [Entry] = [],
        workbookOverride: String? = nil
    ) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        let workbook = workbookOverride ?? """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Summary" sheetId="1" r:id="rId1"/>
            <sheet name="Details &amp; Notes" sheetId="2" r:id="rId2"/>
            \(extraSheetDeclarations)
          </sheets>
        </workbook>
        """
        let targetMode = secondSheetTargetMode.map { " TargetMode=\"\($0)\"" } ?? ""
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"\(targetMode)/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
          <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
          \(extraWorkbookRelationships)
        </Relationships>
        """
        let sharedStrings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="8" uniqueCount="8">
          <si><t>Product</t></si><si><t>Units</t></si><si><t>Äpfel</t></si>
          <si><t>Birnen</t></si><si><t>ID</t></si><si><t>Description</t></si>
          <si><t>A-01</t></si><si><t>Grüße aus Köln</t></si>
        </sst>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="1"><font/></fonts><fills count="1"><fill/></fills>
          <borders count="1"><border/></borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
        </styleSheet>
        """
        return try archive(entries: [
            Entry(name: "[Content_Types].xml", content: Data(contentTypes.utf8)),
            Entry(name: "_rels/.rels", content: Data(rootRelationships.utf8)),
            Entry(name: "xl/workbook.xml", content: Data(workbook.utf8)),
            Entry(name: "xl/_rels/workbook.xml.rels", content: Data(workbookRelationships.utf8)),
            Entry(name: "xl/sharedStrings.xml", content: Data(sharedStrings.utf8)),
            Entry(name: "xl/styles.xml", content: Data(styles.utf8)),
            Entry(name: "xl/worksheets/sheet1.xml", content: Data(firstSheetXML.utf8)),
            Entry(name: "xl/worksheets/sheet2.xml", content: Data(secondSheetXML.utf8)),
        ] + extraEntries)
    }

    static func odmPackage(contentXML: String) throws -> Data {
        try archive(entries: [
            Entry(
                name: "mimetype",
                content: Data("application/vnd.oasis.opendocument.text-master".utf8),
                isStored: true
            ),
            Entry(name: "content.xml", content: Data(contentXML.utf8)),
        ])
    }

    static func archive(entries: [Entry]) throws -> Data {
        var localSection = Data()
        var centralSection = Data()

        for entry in entries {
            let nameBytes = entry.rawNameBytes ?? Data(entry.name.utf8)
            // General-Purpose-Bit 11 setzt jeder regelkonforme Erzeuger, sobald
            // der Name nicht rein ASCII ist — nur damit liest ein Entpacker die
            // Bytes als UTF-8 und nicht als CP437. Die Fixtures schrieben vorher
            // UTF-8-Bytes mit Flags 0 und beschrieben damit ein Archiv, das es so
            // gar nicht gibt (Review-Fund 2026-08-17).
            let flags: UInt16 = entry.explicitFlags
                ?? (entry.name.allSatisfy(\.isASCII) ? 0 : 0x0800)
            let payload = entry.isStored ? entry.content : try deflate(entry.content)
            let method: UInt16 = entry.isStored ? 0 : 8
            let checksum = entry.declaredChecksum ?? crc32(entry.content)
            let declaredSize = UInt32(entry.declaredUncompressedSize ?? entry.content.count)
            let localHeaderOffset = UInt32(localSection.count)

            localSection.appendUInt32(0x0403_4B50)
            localSection.appendUInt16(20)                       // benötigte Version
            localSection.appendUInt16(flags)                    // Flags
            localSection.appendUInt16(method)
            localSection.appendUInt16(0)                        // Uhrzeit
            localSection.appendUInt16(0)                        // Datum
            localSection.appendUInt32(checksum)
            localSection.appendUInt32(UInt32(payload.count))
            localSection.appendUInt32(declaredSize)
            localSection.appendUInt16(UInt16(nameBytes.count))
            localSection.appendUInt16(0)                        // Extrafeld
            localSection.append(nameBytes)
            localSection.append(payload)

            centralSection.appendUInt32(0x0201_4B50)
            centralSection.appendUInt16(20)                     // erzeugende Version, Host 0
            centralSection.appendUInt16(20)                     // benötigte Version
            centralSection.appendUInt16(flags)                  // Flags
            centralSection.appendUInt16(method)
            centralSection.appendUInt16(0)                      // Uhrzeit
            centralSection.appendUInt16(0)                      // Datum
            centralSection.appendUInt32(checksum)
            centralSection.appendUInt32(UInt32(payload.count))
            centralSection.appendUInt32(declaredSize)
            centralSection.appendUInt16(UInt16(nameBytes.count))
            centralSection.appendUInt16(0)                      // Extrafeld
            centralSection.appendUInt16(0)                      // Kommentar
            centralSection.appendUInt16(0)                      // Datenträger
            centralSection.appendUInt16(0)                      // interne Attribute
            centralSection.appendUInt32(0)                      // externe Attribute
            centralSection.appendUInt32(localHeaderOffset)
            centralSection.append(nameBytes)
        }

        var archive = localSection
        let centralOffset = UInt32(archive.count)
        archive.append(centralSection)
        archive.appendUInt32(0x0605_4B50)
        archive.appendUInt16(0)                                 // Datenträgernummer
        archive.appendUInt16(0)                                 // Datenträger mit Verzeichnis
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt32(UInt32(centralSection.count))
        archive.appendUInt32(centralOffset)
        archive.appendUInt16(0)                                 // Archivkommentar
        return archive
    }

    /// Rohes Deflate ohne zlib-Kopf — genau das erwartet ZIP-Methode 8.
    private static func deflate(_ content: Data) throws -> Data {
        guard !content.isEmpty else {
            throw BuilderError.compressionFailed("empty entries are not supported")
        }
        let capacity = content.count + 65_536
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            content.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    content.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else {
            throw BuilderError.compressionFailed("deflate produced no output")
        }
        output.count = written
        return output
    }

    private static func crc32(_ content: Data) -> UInt32 {
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in content {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                checksum = (checksum >> 1) ^ (0xEDB8_8320 & (0 &- (checksum & 1)))
            }
        }
        return checksum ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
        append(UInt8(value >> 16 & 0xFF))
        append(UInt8(value >> 24 & 0xFF))
    }
}
