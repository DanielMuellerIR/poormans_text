import Foundation
import XCTest
@testable import PoorMansTextCore

final class ODSNumberFormatTests: XCTestCase {
    func testFormatsTypedValuesWithoutReplacingVisibleTextOrStoredValues() throws {
        let cases: [(String, String, String, String)] = [
            ("float", "2.675", "Decimal", "2.68"),
            ("percentage", "0.19", "Percent", "19%"),
            ("currency", "1234.5", "Currency", "1.234,50 EUR"),
            ("float", "42", "Identifier", "000042"),
            ("date", "2026-10-16", "Date", "2026-10-16"),
            ("date", "2026-10-16T12:30:45", "DateTime", "2026-10-16 12:30:45"),
            ("time", "PT36H2M3S", "Elapsed", "36:02:03"),
            ("time", "PT18H5M6.25S", "Clock", "18:05:06.25"),
            ("time", "-P1DT12H", "Elapsed", "-36:00:00"),
            ("float", "12345", "Scientific", "1.23E+04"),
            ("float", "46311", "Date", "2026-10-16")
        ]
        let cells = cases.map { cell(type: $0.0, value: $0.1, style: $0.2) }.joined()
            + cell(type: "float", value: "9.75", style: "Missing", text: "Authoritative display")
            + cell(type: "float", value: "2.675", style: "Decimal", text: "")
        let workbook = try ODSWorkbookParser.parse(Data(content(cells: cells).utf8))
        XCTAssertEqual(workbook.sheets[0].rows[0].map(\.displayText), cases.map(\.3) + ["Authoritative display", "2.68"])
        XCTAssertEqual(workbook.sheets[0].rows[0][0].value, .number("2.675"))
        XCTAssertEqual(workbook.sheets[0].rows[0][4].value, .date("2026-10-16"))
        XCTAssertTrue(workbook.locatedDiagnostics.isEmpty, "\(workbook.locatedDiagnostics)")
    }

    func testRowColumnCellAndParentStylesAndRepeatedCells() throws {
        let declarations = """
        <table:table-column table:default-cell-style-name="Percent"/>
        <table:table-column table:default-cell-style-name="Decimal" table:number-columns-repeated="2"/>
        <table:table-column table:default-cell-style-name="Identifier"/>
        """
        let rows = """
        <table:table-row>\(cell(type: "float", value: "0.19", repeatCount: 4))</table:table-row>
        <table:table-row table:default-cell-style-name="Identifier" table:number-rows-repeated="2">
          \(cell(type: "float", value: "42"))\(cell(type: "float", value: "0.19", style: "Inherited"))
        </table:table-row>
        """
        let xml = content(cells: "", extraStyles: "<style:style style:name=\"Inherited\" style:family=\"table-cell\" style:parent-style-name=\"Percent\"/>", declarations: declarations, rows: rows)
        let workbook = try ODSWorkbookParser.parse(Data(xml.utf8))
        XCTAssertEqual(workbook.sheets[0].rows.map { $0.map(\.displayText) }, [["19%", "0.19", "0.19", "000000"], ["000042", "19%"], ["000042", "19%"]])
        XCTAssertTrue(workbook.locatedDiagnostics.isEmpty)
    }

    func testUnsupportedStylesAndInvalidDatesRetainRawValuesAtKnownLocations() throws {
        let cases = [("float", "7.25", "Missing"), ("float", "7.25", "Cycle"),
                     ("float", "7.25", "Fraction"), ("date", "2026-02-30", "Date"),
                     ("date", "2026-10-16T01:30:00+02:00", "DateTime"),
                     ("time", "P1M", "Elapsed"), ("float", "7.25", "Conditional"),
                     ("float", "1junk", "Percent"), ("float", "7.25", "Unspecified")]
        let extra = """
        <style:style style:name="Cycle" style:family="table-cell" style:parent-style-name="Cycle"/>
        <number:number-style style:name="NFraction"><number:fraction/></number:number-style>
        <style:style style:name="Fraction" style:family="table-cell" style:data-style-name="NFraction"/>
        <number:number-style style:name="NConditional"><number:number number:decimal-places="2"/><style:map style:condition="value()&lt;0" style:apply-style-name="NDecimal"/></number:number-style>
        <style:style style:name="Conditional" style:family="table-cell" style:data-style-name="NConditional"/>
        <number:number-style style:name="NUnspecified"><number:number/></number:number-style>
        <style:style style:name="Unspecified" style:family="table-cell" style:data-style-name="NUnspecified"/>
        """
        let workbook = try ODSWorkbookParser.parse(Data(content(cells: cases.map { cell(type: $0.0, value: $0.1, style: $0.2) }.joined(), extraStyles: extra).utf8))
        XCTAssertEqual(workbook.sheets[0].rows[0].map(\.displayText), cases.map(\.1))
        XCTAssertEqual(workbook.locatedDiagnostics.count, cases.count)
        XCTAssertEqual(workbook.locatedDiagnostics.compactMap { $0.location?.cell }, (0..<cases.count).map { String(UnicodeScalar(65 + $0)!) + "1" })
        XCTAssertTrue(workbook.locatedDiagnostics.allSatisfy { $0.code == "spreadsheet.numberFormatNotPreserved" && $0.location?.sheet == "Values" })
    }

    func testNamedStylesDefaultPrecisionAndCustomNullDate() throws {
        let styles = """
        <office:document-styles \(namespaces)><office:styles>
          <style:default-style style:family="table-cell"><style:table-cell-properties style:decimal-places="3"/></style:default-style>
          <number:number-style style:name="NInherited"><number:number number:min-integer-digits="1"/></number:number-style>
          <style:style style:name="Common" style:family="table-cell" style:data-style-name="NInherited"/>
        </office:styles></office:document-styles>
        """
        let xml = content(cells: cell(type: "float", value: "2.6759", style: "Common") + cell(type: "float", value: "0", style: "Date"), nullDate: "2026-10-16")
        let rows = try ODSWorkbookParser.parse(Data(xml.utf8), styles: Data(styles.utf8)).sheets[0].rows
        XCTAssertEqual(rows[0].map(\.displayText), ["2.676", "2026-10-16"])
        XCTAssertEqual(SpreadsheetNumberFormat(code: "yyyy-mm-dd").format("60", dateSystem: .openDocument).text, "1900-02-28")
    }

    func testRealPackagePreservesMarkersFormulaResultsAndSourceInBothRenderers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("values.ods")
        let rows = [("RateMarker", "percentage", "0.19", "Percent", "19%"),
                    ("MoneyMarker", "currency", "1234.5", "Currency", "1.234,50 EUR"),
                    ("DateMarker", "date", "2026-10-16", "Date", "2026-10-16"),
                    ("DurationMarker", "time", "PT36H", "Elapsed", "36:00:00"),
                    ("FormulaMarker", "float", "2.675", "Decimal", "2.68")]
        let body = rows.map { row in
            "<table:table-row>" + cell(type: "string", value: row.0, text: row.0)
                + cell(type: row.1, value: row.2, style: row.3, formula: row.0 == "FormulaMarker" ? "of:=107/40" : nil) + "</table:table-row>"
        }.joined()
        let original = try ZIPFixtureBuilder.odsPackage(contentXML: content(cells: "", rows: body))
        try original.write(to: source)
        for rendering in [SpreadsheetRendering.markdownTable, .tabSeparated] {
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(root.appendingPathComponent(rendering.rawValue)), options: ConversionOptions(spreadsheetRendering: rendering)))
            let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for row in rows {
                XCTAssertEqual(output.components(separatedBy: row.0).count - 1, 1)
                XCTAssertTrue(output.contains(rendering == .markdownTable ? "| \(row.0) | \(row.4) |" : "\(row.0)\t\(row.4)"), output)
            }
            XCTAssertFalse(result.diagnostics.contains { $0.code == "spreadsheet.formulaResultMissing" })
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testStyleAndMaterializedTextBudgetsRejectOversizedInputs() throws {
        for text in [String(repeating: "x", count: 1_048_577)] {
            let xml = content(cells: cell(type: "float", value: "1", style: "Large"), extraStyles: "<number:number-style style:name=\"Large\"><number:text>\(text)</number:text></number:number-style>")
            XCTAssertThrowsError(try ODSWorkbookParser.parse(Data(xml.utf8)))
        }
        for xml in [content(cells: cell(type: "float", value: "12345", style: "Decimal", repeatCount: 4)),
                    content(cells: "", rows: "<table:table-row table:number-rows-repeated=\"4\">\(cell(type: "float", value: "12345", style: "Decimal"))</table:table-row>")] {
            XCTAssertThrowsError(try ODSWorkbookParser.parse(Data(xml.utf8), maximumTextBytes: 20))
        }
        let duplicate = content(cells: "", extraStyles: "<number:number-style style:name=\"NDecimal\"/>")
        XCTAssertThrowsError(try ODSWorkbookParser.parse(Data(duplicate.utf8)))
        let duplicateAttribute = content(cells: "").replacingOccurrences(of: "number:decimal-places=\"2\"", with: "number:decimal-places=\"2\" alias:decimal-places=\"3\" xmlns:alias=\"urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0\"")
        XCTAssertThrowsError(try ODSWorkbookParser.parse(Data(duplicateAttribute.utf8)))
        let entity = content(cells: "").replacingOccurrences(of: "<office:document-content", with: "<!DOCTYPE x [<!ENTITY e 'x'>]><office:document-content")
        XCTAssertThrowsError(try ODSWorkbookParser.parse(Data(entity.utf8)))
    }

    private func cell(type: String, value: String, style: String? = nil, text: String? = nil, repeatCount: Int = 1, formula: String? = nil) -> String {
        let attribute = type == "date" ? "date-value" : type == "time" ? "time-value" : type == "string" ? "string-value" : "value"
        return "<table:table-cell office:value-type=\"\(type)\" office:\(attribute)=\"\(value)\" table:number-columns-repeated=\"\(repeatCount)\""
            + (style.map { " table:style-name=\"\($0)\"" } ?? "") + (formula.map { " table:formula=\"\($0)\"" } ?? "") + ">"
            + (text.map { "<text:p>\($0)</text:p>" } ?? "") + "</table:table-cell>"
    }

    private var namespaces: String {
        """
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
        xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
        xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0"
        """
    }

    private func content(cells: String, extraStyles: String = "", declarations: String = "", rows: String? = nil, nullDate: String = "1899-12-30") -> String {
        let patterns: [(String, String, String, String)] = [
            ("Decimal", "number", "", "<number:number number:decimal-places=\"2\" number:min-integer-digits=\"1\"/>"),
            ("Percent", "percentage", "", "<number:number number:decimal-places=\"0\" number:min-integer-digits=\"1\"/><number:text>%</number:text>"),
            ("Currency", "currency", "number:language=\"de\" number:country=\"DE\"", "<number:number number:decimal-places=\"2\" number:grouping=\"true\" number:min-integer-digits=\"1\"/><number:text> </number:text><number:currency-symbol>EUR</number:currency-symbol>"),
            ("Identifier", "number", "", "<number:number number:decimal-places=\"0\" number:min-integer-digits=\"6\"/>"),
            ("Date", "date", "", "<number:year number:style=\"long\"/><number:text>-</number:text><number:month number:style=\"long\"/><number:text>-</number:text><number:day number:style=\"long\"/>"),
            ("DateTime", "date", "", "<number:year number:style=\"long\"/><number:text>-</number:text><number:month number:style=\"long\"/><number:text>-</number:text><number:day number:style=\"long\"/><number:text> </number:text><number:hours number:style=\"long\"/><number:text>:</number:text><number:minutes number:style=\"long\"/><number:text>:</number:text><number:seconds number:style=\"long\"/>"),
            ("Elapsed", "time", "number:truncate-on-overflow=\"false\"", "<number:hours/><number:text>:</number:text><number:minutes number:style=\"long\"/><number:text>:</number:text><number:seconds number:style=\"long\"/>"),
            ("Clock", "time", "", "<number:hours number:style=\"long\"/><number:text>:</number:text><number:minutes number:style=\"long\"/><number:text>:</number:text><number:seconds number:style=\"long\" number:decimal-places=\"2\"/>"),
            ("Scientific", "number", "", "<number:scientific-number number:decimal-places=\"2\" number:min-integer-digits=\"1\" number:min-exponent-digits=\"2\" number:forced-exponent-sign=\"true\"/>")
        ]
        let styles = patterns.map { "<number:\($0.1)-style style:name=\"N\($0.0)\" \($0.2)>\($0.3)</number:\($0.1)-style><style:style style:name=\"\($0.0)\" style:family=\"table-cell\" style:data-style-name=\"N\($0.0)\"/>" }.joined()
        return "<office:document-content \(namespaces)><office:automatic-styles>\(styles)\(extraStyles)</office:automatic-styles><office:body><office:spreadsheet><table:calculation-settings><table:null-date table:date-value=\"\(nullDate)\"/></table:calculation-settings><table:table table:name=\"Values\">\(declarations)\(rows ?? "<table:table-row>\(cells)</table:table-row>")</table:table></office:spreadsheet></office:body></office:document-content>"
    }
}
