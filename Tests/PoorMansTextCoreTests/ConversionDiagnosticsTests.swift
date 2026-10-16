import Foundation
import XCTest
@testable import PoorMansTextCore

final class ConversionDiagnosticsTests: XCTestCase {
    func testOldJSONAndUnknownFutureKindsRemainReadable() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(ConversionWarning.self, from: Data(#"{"code":"pdf.ocrApplied","message":"OCR"}"#.utf8))
        XCTAssertEqual(old.kind, .information)
        XCTAssertNil(old.location)
        XCTAssertNil(old.omittedCount)
        let future = try decoder.decode(ConversionWarning.self, from: Data(#"{"code":"custom.future","message":"Review","kind":"futureKind","location":{"page":2}}"#.utf8))
        XCTAssertEqual(future.kind, .approximation)
        XCTAssertEqual(future.location, ConversionLocation(page: 2))
    }

    func testNewJSONRoundTripAndRelocationRetainMeaningAndCounts() throws {
        let location = ConversionLocation(page: 2, sheet: "Values", cell: "B3", slide: 4, frame: 5, paragraph: 6, message: "<source@example.invalid>", note: "notes/part.xml")
        let warning = ConversionWarning(code: "custom.loss", message: "Kept text", location: location, kind: .contentLoss, omittedCount: 17)
        XCTAssertEqual(try JSONDecoder().decode(ConversionWarning.self, from: JSONEncoder().encode(warning)), warning)
        let moved = warning.at(location.merging(ConversionLocation(sheet: "Updated")))
        XCTAssertEqual(moved.kind, .contentLoss)
        XCTAssertEqual(moved.omittedCount, 17)
        XCTAssertEqual(moved.location?.sheet, "Updated")
        XCTAssertEqual(moved.location?.paragraph, 6)
    }

    func testKnownLossIsDifferentFromOCRAndUncertainty() {
        XCTAssertEqual(ConversionWarning.pdfOCRApplied.kind, .information)
        XCTAssertEqual(ConversionWarning.imageTextUnavailable.kind, .information)
        XCTAssertEqual(ConversionWarning.pdfPageTextUnavailable.kind, .approximation)
        XCTAssertEqual(ConversionWarning.legacySpreadsheetPotentialLoss.kind, .approximation)
        XCTAssertEqual(ConversionWarning.wordProcessingCommentsNotPreserved.kind, .contentLoss)
        XCTAssertEqual(ConversionWarning.spreadsheetFormulaResultMissing.kind, .contentLoss)
    }

    func testGroupingPreservesDistinctMessagesAndKnownLocationsInOrder() {
        let a = ConversionLocation(page: 2), b = ConversionLocation(page: 1)
        let warnings = [ConversionWarning(code: "x", message: "First", location: a),
                        ConversionWarning.pdfOCRApplied,
                        ConversionWarning(code: "x", message: "Second", location: b),
                        ConversionWarning(code: "x", message: "First", location: a),
                        ConversionWarning(code: "x", message: "Explicit loss", kind: .contentLoss)]
        let groups = ConversionDiagnosticGroup.grouped(warnings)
        XCTAssertEqual(groups.map(\.code), ["x", "pdf.ocrApplied", "x"])
        XCTAssertEqual(groups.map(\.count), [3, 1, 1])
        XCTAssertEqual(groups[0].messages, ["First", "Second"])
        XCTAssertEqual(groups[0].locations, [a, b])
        XCTAssertTrue(groups[1].locations.isEmpty)
    }

    func testLimitCountsOnlyOmittedDiagnosticsAndDoesNotReportAFalseLimit() {
        var diagnostics = BoundedConversionDiagnostics(maximumCount: 2)
        diagnostics.append(.pdfOCRApplied); diagnostics.append(.imageOCRApplied)
        XCTAssertEqual(diagnostics.result.count, 2)
        diagnostics.append(.pdfOCRFailed); diagnostics.append(.imageOCRFailed)
        XCTAssertEqual(diagnostics.result.count, 3)
        XCTAssertEqual(diagnostics.result.last?.omittedCount, 2)
        XCTAssertEqual(diagnostics.result.last?.kind, .information)
        let groups = ConversionDiagnosticGroup.grouped([
            ConversionWarning(code: "diagnostics.limited", message: "A", omittedCount: Int.max),
            ConversionWarning(code: "diagnostics.limited", message: "B", omittedCount: 1)])
        XCTAssertEqual(groups[0].omittedCount, Int.max)
    }

    func testODSCountsOmittedLocationsWhileKeepingEveryCell() throws {
        let cells = (1...300).map { "<table:table-cell office:value-type=\"float\" office:value=\"\($0)\" table:style-name=\"Missing\"/>" }.joined()
        let xml = """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
          <office:body><office:spreadsheet><table:table table:name="Values"><table:table-row>\(cells)</table:table-row></table:table></office:spreadsheet></office:body>
        </office:document-content>
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bounded.ods")
        let original = try ZIPFixtureBuilder.odsPackage(contentXML: xml)
        try original.write(to: source)
        let workbook = try ODSWorkbookParser.parse(Data(xml.utf8))
        XCTAssertEqual(workbook.sheets[0].rows[0].count, 300)
        XCTAssertEqual(workbook.locatedDiagnostics.count, 256)
        XCTAssertEqual(workbook.omittedDiagnosticCount, 44)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertEqual(result.diagnostics.last?.omittedCount, 44)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("| 299 | 300 |"))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testXLSXCountsOmittedLocationsAcrossSheets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = (1...300).map { "<row r=\"\($0)\"><c r=\"A\($0)\" s=\"999\"><v>\($0)</v></c></row>" }.joined()
        let xml = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(body)</sheetData></worksheet>"
        let source = root.appendingPathComponent("bounded.xlsx")
        let original = try ZIPFixtureBuilder.xlsxPackage(firstSheetXML: xml, secondSheetXML: xml)
        try original.write(to: source)
        let workbook = try XLSXWorkbookParser.parse(packageAt: source)
        XCTAssertEqual(workbook.sheets.map { $0.rows.count }, [300, 300])
        XCTAssertEqual(workbook.locatedDiagnostics.count, 256)
        XCTAssertEqual(workbook.omittedDiagnosticCount, 344)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertEqual(result.diagnostics.last?.omittedCount, 344)
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "| 300 |").count - 1, 2)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
