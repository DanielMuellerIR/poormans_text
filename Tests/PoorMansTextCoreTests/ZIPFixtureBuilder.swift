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
    }

    enum BuilderError: Error {
        case compressionFailed(String)
    }

    /// Ein DOCX-ähnliches Paket: die beiden von der Erkennung verlangten
    /// Einträge plus ein Medieneintrag, über den der Test lügen lassen kann.
    static func wordProcessingPackage(
        mediaContent: Data = Data(repeating: 0x2E, count: 4096),
        declaredMediaSize: Int? = nil,
        declaredMediaChecksum: UInt32? = nil
    ) throws -> Data {
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>Fixture text</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>
        """
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

    static func archive(entries: [Entry]) throws -> Data {
        var localSection = Data()
        var centralSection = Data()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let payload = entry.isStored ? entry.content : try deflate(entry.content)
            let method: UInt16 = entry.isStored ? 0 : 8
            let checksum = entry.declaredChecksum ?? crc32(entry.content)
            let declaredSize = UInt32(entry.declaredUncompressedSize ?? entry.content.count)
            let localHeaderOffset = UInt32(localSection.count)

            localSection.appendUInt32(0x0403_4B50)
            localSection.appendUInt16(20)                       // benötigte Version
            localSection.appendUInt16(0)                        // Flags
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
            centralSection.appendUInt16(0)                      // Flags
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
