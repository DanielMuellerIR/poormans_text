import Foundation

/// Begrenzte Little-Endian-Lesezugriffe für OLE und BIFF.
extension Data {
    func legacyUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func legacyUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func legacyDouble(at offset: Int) -> Double {
        guard offset >= 0, offset + 8 <= count else { return .nan }
        var bits: UInt64 = 0
        for index in 0..<8 { bits |= UInt64(self[offset + index]) << UInt64(index * 8) }
        return Double(bitPattern: bits)
    }
}
