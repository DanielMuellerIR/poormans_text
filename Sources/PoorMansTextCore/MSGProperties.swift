import Foundation

/// MSG-Propertytabellen haben je nach Objekt einen anderen Header. Stringlängen
/// zählen den Terminator mit, obwohl er im separaten Wertstream nicht steht.
struct MSGProperties {
    enum ObjectKind: String {
        case root, embedded, object
        var headerSize: Int {
            switch self { case .root: 32; case .embedded: 24; case .object: 8 }
        }
    }

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private let values: [UInt32: Data]
    var tags: Set<UInt32> { Set(values.keys) }
    let recipientCount: Int?
    let attachmentCount: Int?

    init(data: Data, kind: ObjectKind) throws {
        guard data.count >= kind.headerSize, data.count <= 8_000_032,
              (data.count - kind.headerSize) % 16 == 0 else {
            throw Failure(reason: "the MSG property stream is truncated or too large")
        }
        var parsed = [UInt32: Data]()
        for offset in stride(from: kind.headerSize, to: data.count, by: 16) {
            try ConversionExecution.check()
            let tag = data.legacyUInt32(at: offset)
            let start = data.startIndex + offset + 8
            let value = data.subdata(in: start..<(start + 8))
            guard tag != 0, parsed.updateValue(value, forKey: tag) == nil else {
                throw Failure(reason: "the MSG property stream has a duplicate or invalid tag")
            }
        }
        values = parsed
        recipientCount = kind == .object ? nil : Int(data.legacyUInt32(at: 16))
        attachmentCount = kind == .object ? nil : Int(data.legacyUInt32(at: 20))
    }

    func integer(_ id: UInt16) -> UInt32? {
        values[UInt32(id) << 16 | 0x0003]?.legacyUInt32(at: 0)
    }

    func fileTime(_ id: UInt16) -> Date? {
        guard let bytes = values[UInt32(id) << 16 | 0x0040] else { return nil }
        let ticks = UInt64(bytes.legacyUInt32(at: 0)) | UInt64(bytes.legacyUInt32(at: 4)) << 32
        guard ticks != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
    }

    func stream(_ tag: UInt32, in tree: OLECompoundDocument.StorageTree, storage: [String]) throws -> Data? {
        guard values[tag] != nil else { return nil }
        let name = String(format: "__substg1.0_%08X", tag)
        guard let data = try tree.stream(at: storage + [name]) else {
            throw Failure(reason: "a MSG property value stream is missing")
        }
        return try checkedValue(data, for: tag)
    }

    func checkedValue(_ data: Data, for tag: UInt32) throws -> Data {
        guard let descriptor = values[tag] else {
            throw Failure(reason: "a MSG value has no property table entry")
        }
        let extra: Int
        switch tag & 0xFFFF {
        case 0x001F: extra = 2
        case 0x001E: extra = 1
        case 0x0102: extra = 0
        default: throw Failure(reason: "the MSG property is not a supported single value stream")
        }
        // Outlook-Fixtures enthalten auch leere optionale Stringproperties.
        // Ihre exakte deklarierte Länge bleibt verbindlich.
        guard data.count + extra == Int(descriptor.legacyUInt32(at: 0)) else {
            throw Failure(reason: "a MSG property value has an invalid byte count")
        }
        return data
    }

    func decodedString(_ data: Data, for tag: UInt32, ansiEncoding: String.Encoding) throws -> String {
        let bytes = try checkedValue(data, for: tag)
        let encoding: String.Encoding
        switch tag & 0xFFFF {
        case 0x001F:
            guard bytes.count % 2 == 0 else {
                throw Failure(reason: "the MSG Unicode string has an odd byte count")
            }
            encoding = .utf16LittleEndian
        case 0x001E: encoding = ansiEncoding
        default: throw Failure(reason: "the MSG property is not a string")
        }
        guard var result = String(data: bytes, encoding: encoding) else {
            throw Failure(reason: "the MSG string encoding is invalid")
        }
        // Manche Outlook-Streams speichern zusätzlich einen abschließenden NUL.
        // Ein NUL innerhalb des Inhalts darf dagegen keine Teilnachricht verstecken.
        if result.last == "\0" { result.removeLast() }
        guard !result.contains("\0") else {
            throw Failure(reason: "the MSG string contains an internal null character")
        }
        return result
    }
}
