import Foundation

/// MS-OXRTFCP verwendet eine vorbereitete 4-KiB-Dictionary und CRC ohne
/// Anfangs-/Endinversion. Ein bloßes zlib-Dekodieren wäre ein anderer Algorithmus.
enum MSGCompressedRTF {
    static let maximumBytes = 64 * 1024 * 1024
    private static let seed = Array((#"{\rtf1\ansi\mac\deff0\deftab720{\fonttbl;}{\f0\fnil \froman \fswiss \fmodern \fscript \fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\colortbl\red0\green0\blue0"# + "\r\n" + #"\par \pard\plain\f0\fs20\b\i\u\tab\tx"#).utf8)
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        return crc
    }

    static func decode(_ data: Data) throws -> Data {
        func failure(_ reason: String) -> MSGProperties.Failure { .init(reason: reason) }
        guard data.count >= 16, data.count <= maximumBytes,
              UInt64(data.legacyUInt32(at: 0)) + 4 == UInt64(data.count) else {
            throw failure("the compressed MSG RTF header or size is invalid")
        }
        let size = Int(data.legacyUInt32(at: 4))
        guard size > 0, size <= maximumBytes else { throw failure("the expanded MSG RTF exceeds the size limit") }
        let payload = Array(data.dropFirst(16))
        let magic = data.legacyUInt32(at: 8)
        if magic == 0x414C454D {
            guard payload.count == size, data.legacyUInt32(at: 12) == 0 else {
                throw failure("the uncompressed MSG RTF length or CRC is invalid")
            }
            return Data(payload)
        }
        guard magic == 0x75465A4C else { throw failure("the MSG RTF compression type is unsupported") }
        var crc: UInt32 = 0
        for (index, byte) in payload.enumerated() {
            if index % 4096 == 0 { try ConversionExecution.check() }
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)]
        }
        guard crc == data.legacyUInt32(at: 12) else { throw failure("the MSG RTF CRC is invalid") }
        var dictionary = [UInt8](repeating: 0, count: 4096)
        var initialized = [Bool](repeating: false, count: 4096)
        for (index, byte) in seed.enumerated() { dictionary[index] = byte; initialized[index] = true }
        var write = seed.count
        var position = 0
        var output = Data()
        output.reserveCapacity(size)
        func emit(_ byte: UInt8) throws {
            guard output.count < size else { throw failure("the MSG RTF expands beyond its declared length") }
            output.append(byte)
            dictionary[write] = byte
            initialized[write] = true
            write = (write + 1) & 4095
        }
        while position < payload.count {
            try ConversionExecution.check()
            let control = payload[position]; position += 1
            for bit in 0..<8 {
                if control & (1 << bit) != 0 {
                    guard position + 2 <= payload.count else { throw failure("the MSG RTF dictionary reference is truncated") }
                    let reference = Int(payload[position]) << 8 | Int(payload[position + 1]); position += 2
                    let offset = reference >> 4
                    if offset == write {
                        guard output.count == size, position == payload.count else {
                            throw failure("the MSG RTF terminator or expanded length is invalid")
                        }
                        return output
                    }
                    for step in 0..<((reference & 15) + 2) {
                        let index = (offset + step) & 4095
                        guard initialized[index] else { throw failure("the MSG RTF references uninitialized dictionary bytes") }
                        try emit(dictionary[index])
                    }
                } else {
                    guard position < payload.count else { throw failure("the MSG RTF literal is truncated") }
                    let byte = payload[position]; position += 1
                    try emit(byte)
                }
            }
        }
        throw failure("the MSG RTF end marker is missing")
    }
}
