import Foundation
import XCTest
@testable import PoorMansTextCore

/// Die drei Lesezugriffe heißen „begrenzt". Für eine Teilfolge waren sie es
/// nicht: `Data` rebasiert nicht, der Wächter prüfte gegen `count` und der
/// Zugriff lief über absolute Indizes (Review-Fund 2026-09-10).
final class BinaryDataReadingTests: XCTestCase {
    private let bytes = Data([0x00, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA])

    func testTheReadsAreRelativeToTheStartIndexOfASlice() {
        let slice = bytes[2...]

        XCTAssertEqual(slice.legacyUInt16(at: 0), 0x2211)
        XCTAssertEqual(slice.legacyUInt32(at: 0), 0x44332211)
        XCTAssertEqual(slice.legacyUInt16(at: 4), 0x6655)
        // Dieselben Werte wie über die rebasierte Kopie.
        let copy = bytes.subdata(in: 2..<bytes.count)
        XCTAssertEqual(slice.legacyUInt16(at: 0), copy.legacyUInt16(at: 0))
        XCTAssertEqual(slice.legacyUInt32(at: 2), copy.legacyUInt32(at: 2))
        XCTAssertEqual(slice.legacyDouble(at: 0), copy.legacyDouble(at: 0))
    }

    func testAnOutOfRangeReadYieldsTheNeutralValueInsteadOfTrapping() {
        let slice = bytes[8...]

        XCTAssertEqual(slice.legacyUInt16(at: 3), 0)
        XCTAssertEqual(slice.legacyUInt32(at: 1), 0)
        XCTAssertEqual(slice.legacyUInt16(at: -1), 0)
        XCTAssertTrue(slice.legacyDouble(at: 0).isNaN)
    }
}
