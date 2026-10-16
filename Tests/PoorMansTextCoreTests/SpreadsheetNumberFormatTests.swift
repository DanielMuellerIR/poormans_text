import Foundation
import XCTest
@testable import PoorMansTextCore

final class SpreadsheetNumberFormatTests: XCTestCase {
    func testNumericMeaningAndDecimalRounding() {
        let cases: [(String, String, String)] = [
            ("0.19", "0%", "19%"), ("0.1955", "0.00%", "19.55%"),
            ("1234.5", #"0.00" EUR""#, "1234.50 EUR"),
            ("42", "000000", "000042"), ("2.675", "0.00", "2.68"),
            ("9007199254740993", "0", "9007199254740993"),
            ("1234567.8", "#,##0.00", "1,234,567.80"),
            ("-1234.5", "#,##0.00;[Red](#,##0.00)", "(1,234.50)"),
            ("2.5", "0.###", "2.5"), ("0.5", "#.00", ".50"),
            ("1500", #"[>=1000]0.0,"k";0.0"#, "1.5k"),
            ("500", #"[>=1000]0.0,"k";0.0"#, "500.0"),
            ("1.25", #"0.00"; EUR""#, "1.25; EUR"),
            ("0.19", #"0.0\%"#, "0.2%"),
            ("1234.5", "[$€-407]#,##0.00", "€1.234,50"),
            ("12345", "0.00E+00", "1.23E+04"),
            ("12345", "##0.0E+0", "12.3E+3"),
            ("999.999", "0.00E+00", "1.00E+03")
        ]
        for (value, code, expected) in cases {
            let result = SpreadsheetNumberFormat(code: code).format(value)
            XCTAssertEqual(result.text, expected, "\(value), \(code): \(result.issue ?? "")")
            XCTAssertNil(result.issue, "\(code): \(result.issue ?? "")")
        }
    }

    func testDatesTimesDurationsAndExcelLeapDay() {
        let cases: [(String, String, SpreadsheetDateSystem, String)] = [
            ("1", "yyyy-mm-dd", .excel1900, "1900-01-01"),
            ("59", "yyyy-mm-dd", .excel1900, "1900-02-28"),
            ("61", "yyyy-mm-dd", .excel1900, "1900-03-01"),
            ("0", "yyyy-mm-dd", .excel1904, "1904-01-01"),
            ("46311", "yyyy-mm-dd", .excel1900, "2026-10-16"),
            ("44849", "yyyy-mm-dd", .excel1904, "2026-10-16"),
            ("46311.5", "yyyy-mm-dd hh:mm:ss", .excel1900, "2026-10-16 12:00:00"),
            ("0.75", "h:mm AM/PM", .excel1900, "6:00 PM"),
            ("0", "hh:mm:ss", .excel1900, "00:00:00"),
            ("1.5", "[h]:mm:ss", .excel1900, "36:00:00"),
            ("1.5", "[mm]:ss", .excel1900, "2160:00"),
            ("0.000011574074074", "[ss].000", .excel1900, "01.000"),
            ("-1.5", "[h]:mm:ss", .excel1900, "-36:00:00"),
            ("46311", "[$-407]dddd, d. mmmm yyyy", .excel1900, "Freitag, 16. Oktober 2026")
        ]
        for (value, code, system, expected) in cases {
            let result = SpreadsheetNumberFormat(code: code).format(value, dateSystem: system)
            XCTAssertEqual(result.text, expected, "\(value), \(code): \(result.issue ?? "")")
            XCTAssertNil(result.issue)
        }
        let leap = SpreadsheetNumberFormat(code: "yyyy-mm-dd").format("60")
        XCTAssertEqual(leap.text, "1900-02-29")
        XCTAssertTrue(leap.issue?.contains("fictitious") == true)
    }

    func testDateOnlyDoesNotRoundAcrossMidnight() {
        for (serial, system) in [("46311", SpreadsheetDateSystem.excel1900), ("44849", .excel1904), ("46311", .openDocument)] {
            let expected = "2026-10-16"
            for fraction in [".999999", ".999999999999999999"] {
                let result = SpreadsheetNumberFormat(code: "yyyy-mm-dd").format(serial + fraction, dateSystem: system)
                XCTAssertEqual(result.text, expected)
                XCTAssertNil(result.issue)
            }
        }
        XCTAssertEqual(SpreadsheetNumberFormat(code: "yyyy-mm-dd").format("59.999999").text, "1900-02-28")
        XCTAssertEqual(SpreadsheetNumberFormat(code: "yyyy-mm-dd").format("61.999999").text, "1900-03-01")
        XCTAssertEqual(SpreadsheetNumberFormat(code: "yyyy-mm-dd hh:mm").format("46311.999999").text, "2026-10-16 23:59")
        XCTAssertEqual(SpreadsheetNumberFormat(code: "yyyy-mm-dd hh:mm:ss").format("46311.999999").text, "2026-10-17 00:00:00")
    }

    func testUnsupportedOrHiddenMeaningRetainsStoredValue() {
        for code in ["# ?/?", "[DBNum1]0", "[$-ffff]0.00", "0;0;", "0.00\"unfinished",
                     String(repeating: "0", count: 1_025), "0.00/00", #""hidden""#] {
            let result = SpreadsheetNumberFormat(code: code).format("0")
            XCTAssertEqual(result.text, "0", code)
            XCTAssertNotNil(result.issue, code)
        }
        for value in ["-1", "0", "99999999999999999999"] {
            let result = SpreadsheetNumberFormat(code: "yyyy-mm-dd").format(value)
            XCTAssertEqual(result.text, value)
            XCTAssertNotNil(result.issue)
        }
        XCTAssertEqual(SpreadsheetNumberFormat(code: "General").format("1.234567890123456789e+60").text,
                       "1.234567890123456789e+60")
    }

    func testRealWorkbookPreservesAllCellsAndSourceInBothRenderers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows: [(String, String, Int, String)] = [
            ("DateMarker", "46311", 1, "2026-10-16"),
            ("RateMarker", "0.19", 2, "19%"),
            ("MoneyMarker", "1234.5", 3, "1234.50 EUR"),
            ("IdentifierMarker", "42", 4, "000042"),
            ("FormulaMarker", "2.675", 5, "2.68"),
            ("GeneralMarker", "1.23456789", 0, "1.23456789"),
            ("UnknownMarker", "7.25", 6, "7.25")
        ]
        let body = rows.enumerated().map { index, row in
            "<row r=\"\(index + 2)\"><c r=\"A\(index + 2)\" t=\"inlineStr\"><is><t>\(row.0)</t></is></c>"
                + "<c r=\"B\(index + 2)\" s=\"\(row.2)\">\(index == 4 ? "<f>107/40</f>" : "")<v>\(row.1)</v></c></row>"
        }.joined()
        let source = root.appendingPathComponent("formatted.xlsx")
        let original = try workbook(body: body, codes: [164: "yyyy-mm-dd", 165: "0%", 166: #"0.00" EUR""#,
                                                       167: "000000", 168: "0.00", 169: "# ?/?"],
                                    formatIDs: [0, 164, 165, 166, 167, 168, 169])
        try original.write(to: source)
        let parsed = try XLSXWorkbookParser.parse(packageAt: source)
        XCTAssertEqual(parsed.sheets[0].rows.count, rows.count + 1)
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(parsed.sheets[0].rows[index + 1][1].value, .number(row.1))
        }
        for style in [SpreadsheetRendering.markdownTable, .tabSeparated] {
            let result = try DocumentConverter().convert(ConversionRequest(
                inputURL: source, destination: .directory(root.appendingPathComponent(style.rawValue)),
                options: ConversionOptions(spreadsheetRendering: style)
            ))
            let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for row in rows {
                XCTAssertEqual(text.components(separatedBy: row.0).count - 1, 1)
                XCTAssertTrue(text.contains(style == .markdownTable ? "| \(row.0) | \(row.3) |" : "\(row.0)\t\(row.3)"), text)
            }
            let warning = try XCTUnwrap(result.diagnostics.first { $0.code == "spreadsheet.numberFormatNotPreserved" })
            XCTAssertEqual(warning.location, ConversionLocation(sheet: "Values", cell: "B8"))
            XCTAssertFalse(result.diagnostics.contains { $0.code == "spreadsheet.formulaResultMissing" })
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testRowColumnAndBaseStylesAnd1904DateSystem() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("inherited.xlsx")
        let body = """
        <row r="2"><c r="A2" t="inlineStr"><is><t>Column</t></is></c><c r="B2"><v>44849</v></c></row>
        <row r="3" s="2" customFormat="1"><c r="A3" t="inlineStr"><is><t>Row</t></is></c><c r="B3"><v>0.19</v></c></row>
        <row r="4" s="2" customFormat="1"><c r="A4" t="inlineStr"><is><t>Cell</t></is></c><c r="B4" s="0"><v>0.19</v></c></row>
        <row r="5"><c r="A5" t="inlineStr"><is><t>Base</t></is></c><c r="B5" s="3"><v>44849</v></c></row>
        """
        try workbook(body: body, codes: [164: "yyyy-mm-dd"], formatIDs: [0, 164, 9], date1904: true,
                     columns: "<cols><col min=\"2\" max=\"2\" style=\"1\"/></cols>",
                     extraStyles: "<xf xfId=\"0\" applyNumberFormat=\"0\" numFmtId=\"0\"/>", baseFormat: 164).write(to: source)
        let rows = try XLSXWorkbookParser.parse(packageAt: source).sheets[0].rows
        XCTAssertEqual(rows.dropFirst().map { $0[1].displayText }, ["2026-10-16", "19%", "0.19", "2026-10-16"])
    }

    func testBadStylesAreBoundedAndReferencesDiagnosed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bad-index.xlsx")
        try workbook(body: "<row r=\"2\"><c r=\"A2\" s=\"99\"><v>12</v></c></row>", codes: [:], formatIDs: [0]).write(to: source)
        let parsed = try XLSXWorkbookParser.parse(packageAt: source)
        XCTAssertEqual(parsed.sheets[0].rows[1][0].displayText, "12")
        XCTAssertEqual(parsed.locatedDiagnostics.first?.location?.cell, "A2")
        let inherited = root.appendingPathComponent("bad-base.xlsx")
        try workbook(body: "<row r=\"2\"><c r=\"A2\" s=\"1\"><v>12</v></c></row>", codes: [:], formatIDs: [0],
                     extraStyles: "<xf xfId=\"99\" applyNumberFormat=\"0\"/>").write(to: inherited)
        let badBase = try XLSXWorkbookParser.parse(packageAt: inherited)
        XCTAssertEqual(badBase.sheets[0].rows[1][0].displayText, "12")
        XCTAssertTrue(badBase.locatedDiagnostics[0].message.contains("inherited"))
        XCTAssertThrowsError(try XLSXNumberStyles(Data("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts><numFmt numFmtId=\"164\" formatCode=\"0\"/><numFmt numFmtId=\"164\" formatCode=\"0\"/></numFmts></styleSheet>".utf8)))
        XCTAssertThrowsError(try XLSXNumberStyles(Data("<!DOCTYPE styleSheet [<!ENTITY x '0'>]><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts><numFmt numFmtId=\"164\" formatCode=\"&x;\"/></numFmts></styleSheet>".utf8)))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTNumberFormat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func workbook(body: String, codes: [Int: String], formatIDs: [Int], date1904: Bool = false,
                          columns: String = "", extraStyles: String = "", baseFormat: Int = 0) throws -> Data {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let formats = codes.sorted { $0.key < $1.key }.map { "<numFmt numFmtId=\"\($0.key)\" formatCode=\"\(escape($0.value))\"/>" }.joined()
        let styles = formatIDs.map { "<xf numFmtId=\"\($0)\"/>" }.joined() + extraStyles
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/package/2006/relationships"
        let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let parts = [
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/></Types>",
            "xl/workbook.xml": "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(office)\"><workbookPr date1904=\"\(date1904 ? 1 : 0)\"/><sheets><sheet name=\"Values\" sheetId=\"1\" r:id=\"r1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"r1\" Type=\"\(office)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"r2\" Type=\"\(office)/styles\" Target=\"styles.xml\"/></Relationships>",
            "xl/styles.xml": "<styleSheet xmlns=\"\(ns)\"><numFmts>\(formats)</numFmts><cellStyleXfs><xf numFmtId=\"\(baseFormat)\"/></cellStyleXfs><cellXfs>\(styles)</cellXfs></styleSheet>",
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(ns)\">\(columns)<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Meaning</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Value</t></is></c></row>\(body)</sheetData></worksheet>"
        ]
        return try ZIPFixtureBuilder.archive(entries: parts.sorted { $0.key < $1.key }.map { .init(name: $0.key, content: Data($0.value.utf8)) })
    }
}
