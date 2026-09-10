import Foundation

/// Begrenzte Little-Endian-Lesezugriffe für OLE und BIFF.
///
/// Alle drei Zugriffe zählen ab `startIndex`, nicht ab 0. `Data` rebasiert eine
/// Teilfolge NICHT: `daten[100..<200]` hat `count == 100`, aber `startIndex ==
/// 100`. Der Wächter `offset + 2 <= count` sah deshalb bei einer Teilfolge
/// richtig aus, und der Zugriff `self[0]` beendete den Prozess trotzdem. Heute
/// reicht kein Aufrufer eine Teilfolge herein — alle benutzen `subdata`, das
/// rebasiert —, aber ein Leser, der „begrenzt" heißt, darf daran nicht hängen
/// (Review-Fund 2026-09-10).
extension Data {
    func legacyUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func legacyUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }

    func legacyDouble(at offset: Int) -> Double {
        guard offset >= 0, offset + 8 <= count else { return .nan }
        let base = startIndex + offset
        var bits: UInt64 = 0
        for index in 0..<8 { bits |= UInt64(self[base + index]) << UInt64(index * 8) }
        return Double(bitPattern: bits)
    }
}
