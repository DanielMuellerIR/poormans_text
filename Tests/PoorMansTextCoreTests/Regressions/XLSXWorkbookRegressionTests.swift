import Foundation
import XCTest
@testable import PoorMansTextCore

final class XLSXWorkbookRegressionTests: XCTestCase {
    /// Zeigten mehrere Blätter auf dieselbe Blattdatei, wurde dieselbe XML
    /// mehrfach entpackt und mehrfach geparst — bei 256 erlaubten Blättern viel
    /// Arbeit aus einer winzigen Datei.
    func testWorkbookRejectsTwoSheetsPointingAtTheSameWorksheetPart() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let sourceURL = temporaryDirectory.appendingPathComponent("Doppelt.xlsx")
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Summary" sheetId="1" r:id="rId1"/>
            <sheet name="Kopie" sheetId="2" r:id="rId1"/>
          </sheets>
        </workbook>
        """
        try ZIPFixtureBuilder.xlsxPackage(
            firstSheetXML: worksheetXML,
            secondSheetXML: worksheetXML,
            workbookOverride: workbook
        ).write(to: sourceURL)

        XCTAssertThrowsError(try XLSXWorkbookParser.parse(packageAt: sourceURL)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("same worksheet part"),
                "Unerwarteter Fehler: \(error.localizedDescription)"
            )
        }
    }

    /// Gegenprobe: Zwei eigene Blattdateien bleiben eine gültige Arbeitsmappe.
    func testWorkbookWithTwoDistinctWorksheetPartsStillParses() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let sourceURL = temporaryDirectory.appendingPathComponent("Normal.xlsx")
        try ZIPFixtureBuilder.xlsxPackage(
            firstSheetXML: worksheetXML,
            secondSheetXML: worksheetXML
        ).write(to: sourceURL)

        let parsed = try XLSXWorkbookParser.parse(packageAt: sourceURL)

        XCTAssertEqual(parsed.sheets.count, 2)
    }

    private var worksheetXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>12</v></c></row>
          </sheetData>
        </worksheet>
        """
    }

    func testBooleanFormulaWithoutCachedValueStaysEmptyAndWarns() throws {
        let root = try makeRegressionDirectory()
        let sheet = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="b"><f>1=1</f></c><c r="B1" t="b"><f>1=1</f><v/></c><c r="C1" t="b"><v>0</v></c><c r="D1" t="b"><v>1</v></c></row></sheetData></worksheet>"#
        let source = root.appendingPathComponent("boolean.xlsx")
        let bytes = try ZIPFixtureBuilder.xlsxPackage(firstSheetXML: sheet, secondSheetXML: #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>"#)
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "FALSE").count - 1, 1, markdown)
        XCTAssertEqual(markdown.components(separatedBy: "TRUE").count - 1, 1, markdown)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "spreadsheet.formulaResultMissing" })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testRealXLSXPreservesPreciseDateTimeAndElapsedMinutesInBothRenderings() throws {
        let root = try makeRegressionDirectory()
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let parts = [
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/></Types>",
            "xl/workbook.xml": "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(office)\"><sheets><sheet name=\"Values\" sheetId=\"1\" r:id=\"r1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"\(office)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"r2\" Type=\"\(office)/styles\" Target=\"styles.xml\"/></Relationships>",
            "xl/styles.xml": "<styleSheet xmlns=\"\(ns)\"><numFmts><numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd hh:mm\"/><numFmt numFmtId=\"165\" formatCode=\"[h]:mm\"/></numFmts><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"164\"/><xf numFmtId=\"165\"/></cellXfs></styleSheet>",
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(ns)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Meaning</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Value</t></is></c></row><row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t>DateAndTime</t></is></c><c r=\"B2\" s=\"1\"><v>46311.999999999999999999</v></c></row><row r=\"3\"><c r=\"A3\" t=\"inlineStr\"><is><t>Elapsed</t></is></c><c r=\"B3\" s=\"2\"><v>1.999999999999999999</v></c></row></sheetData></worksheet>"
        ]
        let source = root.appendingPathComponent("precise.xlsx")
        try ZIPFixtureBuilder.archive(entries: parts.sorted { $0.key < $1.key }.map { .init(name: $0.key, content: Data($0.value.utf8)) }).write(to: source)
        let bytes = try Data(contentsOf: source)
        let parsed = try XLSXWorkbookParser.parse(packageAt: source)
        XCTAssertEqual(parsed.sheets[0].rows[1][1].value, .number("46311.999999999999999999"))
        for rendering in [SpreadsheetRendering.markdownTable, .tabSeparated] {
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(rendering.rawValue)), options: .init(spreadsheetRendering: rendering, conversionReport: true)))
            let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for marker in ["DateAndTime", "Elapsed", "2026-10-16 23:59", "47:59"] { XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, text) }
            XCTAssertFalse(result.diagnostics.contains { $0.code == "spreadsheet.numberFormatNotPreserved" })
            XCTAssertEqual(result.sourceIdentity?.sha256, ConversionFileFingerprint.digest(bytes))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
}
