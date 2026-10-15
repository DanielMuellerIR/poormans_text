import Foundation
import XCTest
@testable import PoorMansTextCore

final class LegacyXLSNumberFormatTests: XCTestCase {
    func testAllNumericRecordKindsUseStylesAndPreserveCachedValues() throws {
        let bytes = try fixture()
        let workbook = try LegacyXLSWorkbookParser.parse(bytes)
        let rows = workbook.sheets[0].rows
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows[1][0].displayText, "2026-10-16")
        XCTAssertEqual(rows[1][0].value, .number("46311"))
        XCTAssertEqual(rows[2][0].displayText, "19%")
        XCTAssertEqual(rows[2][0].value, .number("0.19"))
        XCTAssertEqual(rows[3].map(\.displayText), ["000042", "12.34 €"])
        XCTAssertEqual(rows[4][0].displayText, "2.68")
        XCTAssertNotNil(rows[4][0].formula)
        XCTAssertEqual(rows[4][0].value, .number("2.675"))
        XCTAssertEqual(rows[5][0].displayText, "36:00:00")
        XCTAssertEqual(rows[6][0].displayText, "7.25")
        XCTAssertEqual(workbook.locatedDiagnostics.map(\.location), [ConversionLocation(sheet: "Values", cell: "A7")])
        XCTAssertEqual(rows[7][0].displayText, "1,234.50")
    }

    func test1904DateSystemAndCompressedUnicodeFormatLiteral() throws {
        let workbook = try LegacyXLSWorkbookParser.parse(fixture(date1904: true, compressedLiteral: true))
        XCTAssertEqual(workbook.sheets[0].rows[1][0].displayText, "2026-10-16")
        XCTAssertEqual(workbook.sheets[0].rows[3][1].displayText, "12.34 Ä")
    }

    func testInheritedNumberStylesAndInvalidReferences() throws {
        let extra = xf(format: 167, style: true) + xf(format: 0, parent: 8, applies: false)
            + xf(format: 0, parent: 99, applies: false) + xf(format: 0, style: true, applies: true)
            + xf(format: 2, parent: 11, applies: false)
        let cells = number(row: 8, column: 0, style: 9, value: 0.19)
            + number(row: 9, column: 0, style: 10, value: 12.5)
            + number(row: 10, column: 0, style: 12, value: 12.5)
        let workbook = try LegacyXLSWorkbookParser.parse(fixture(extraStyles: extra, extraCells: cells))
        XCTAssertEqual(workbook.sheets[0].rows[8][0].displayText, "19%")
        XCTAssertEqual(workbook.sheets[0].rows[9][0].displayText, "12.5")
        XCTAssertEqual(workbook.sheets[0].rows[10][0].displayText, "12.50")
        XCTAssertTrue(workbook.locatedDiagnostics.contains { $0.location?.cell == "A10" && $0.message.contains("inherited") })
    }

    func testRealOLEConversionKeepsSourceAndEveryNumericCellInBothRenderers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XLSFormats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("styled.xls")
        let bytes = try fixture()
        try bytes.write(to: source)
        for renderer in [SpreadsheetRendering.markdownTable, .tabSeparated] {
            let result = try DocumentConverter().convert(ConversionRequest(
                inputURL: source, destination: .directory(root.appendingPathComponent(renderer.rawValue)),
                options: ConversionOptions(spreadsheetRendering: renderer)
            ))
            let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for expected in ["2026-10-16", "19%", "000042", "12.34 €", "2.68", "36:00:00", "7.25", "1,234.50"] {
                XCTAssertEqual(output.components(separatedBy: expected).count - 1, 1, output)
            }
            XCTAssertTrue(result.diagnostics.contains { $0.code == "legacySpreadsheet.potentialLoss" && $0.location == nil })
            XCTAssertTrue(result.diagnostics.contains { $0.code == "spreadsheet.numberFormatNotPreserved" && $0.location?.cell == "A7" })
            XCTAssertFalse(result.diagnostics.contains { $0.code == "spreadsheet.formulaResultMissing" })
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testInvalidFormatRecordsFailWithoutPublishing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BadXLSFormats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, bad) in [record(0x00e0, Data(repeating: 0, count: 19)),
                             formatRecord(164, "0.00"),
                             record(0x0022, le(2, 2)),
                             record(0x041e, le(170, 2) + le(1, 2) + Data([1, 0x00, 0xd8]))].enumerated() {
            let source = root.appendingPathComponent("bad-\(index).xls")
            let bytes = try fixture(extraGlobals: bad)
            try bytes.write(to: source)
            let output = root.appendingPathComponent("out-\(index)")
            XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(output))))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testFormatStringMayContinueAcrossBIFFRecords() throws {
        let first = record(0x041e, le(168, 2) + le(10, 2) + Data([0]) + Data("0.00\"".utf8))
        let continuation = record(0x003c, Data([0]) + Data(" EUR\"".utf8))
        let extra = first + continuation
        let workbook = try LegacyXLSWorkbookParser.parse(fixture(extraStyles: xf(format: 168),
            extraCells: number(row: 8, column: 0, style: 8, value: 12.5), extraGlobals: extra))
        XCTAssertEqual(workbook.sheets[0].rows[8][0].displayText, "12.50 EUR")
    }

    private func fixture(date1904: Bool = false, compressedLiteral: Bool = false, extraStyles: Data = Data(),
                         extraCells: Data = Data(), extraGlobals: Data = Data()) throws -> Data {
        let formats = formatRecord(164, "yyyy-mm-dd") + formatRecord(165, compressedLiteral ? #"0.00" Ä""# : #"0.00" €""#, wide: !compressedLiteral)
            + formatRecord(166, "000000") + formatRecord(167, "0%")
        let styles = xf(format: 0, style: true) + xf(format: 164) + xf(format: 9)
            + xf(format: 166) + xf(format: 165) + xf(format: 2) + xf(format: 46) + xf(format: 4) + extraStyles
        var rk = le(2, 2) + le(0, 2) + le(2, 2)
        rk += le((19 << 2) | 3, 4)
        let multiple = le(3, 2) + le(0, 2) + le(3, 2) + le((42 << 2) | 2, 4)
            + le(4, 2) + le((1234 << 2) | 3, 4) + le(1, 2)
        let formula = le(4, 2) + le(0, 2) + le(5, 2) + le(Double(2.675).bitPattern, 8) + Data(repeating: 0, count: 8)
        var sheet = record(0x0809, le(0x0600, 2) + le(0x0010, 2))
        sheet += number(row: 0, column: 0, style: 0, value: 777)
        sheet += number(row: 1, column: 0, style: 1, value: date1904 ? 44849 : 46311)
        sheet += record(0x027e, rk)
        sheet += record(0x00bd, multiple)
        sheet += record(0x0006, formula)
        sheet += number(row: 5, column: 0, style: 6, value: 1.5)
        sheet += number(row: 6, column: 0, style: 99, value: 7.25)
        sheet += number(row: 7, column: 0, style: 7, value: 1234.5)
        sheet += extraCells
        sheet += record(0x000a, Data())
        let beforeBounds = record(0x0809, le(0x0600, 2) + le(0x0005, 2)) + record(0x0022, le(date1904 ? 1 : 0, 2))
            + formats + styles + extraGlobals
        let boundLength = 4 + 8 + "Values".utf8.count
        let offset = beforeBounds.count + boundLength + 4
        let bound = record(0x0085, le(UInt64(offset), 4) + Data([0, 0, 6, 0]) + Data("Values".utf8))
        return try MSGEmbeddedWriter.compound([["Workbook"]: beforeBounds + bound + record(0x000a, Data()) + sheet])
    }

    private func xf(format: UInt64, style: Bool = false, parent: UInt64 = 0, applies: Bool? = nil) -> Data {
        var payload = Data(repeating: 0, count: 20)
        payload.replaceSubrange(2..<4, with: le(format, 2))
        payload.replaceSubrange(4..<6, with: le(style ? 0xfff4 : parent << 4, 2))
        payload[9] = (applies ?? !style) ? 4 : 0
        return record(0x00e0, payload)
    }

    private func formatRecord(_ id: UInt64, _ code: String, wide: Bool = true) -> Data {
        let text = wide ? code.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
            : code.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
        return record(0x041e, le(id, 2) + le(UInt64(code.utf16.count), 2) + Data([wide ? 1 : 0]) + Data(text))
    }

    private func number(row: UInt64, column: UInt64, style: UInt64, value: Double) -> Data {
        record(0x0203, le(row, 2) + le(column, 2) + le(style, 2) + le(value.bitPattern, 8))
    }

    private func record(_ id: UInt64, _ payload: Data) -> Data { le(id, 2) + le(UInt64(payload.count), 2) + payload }
    private func le(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
}
