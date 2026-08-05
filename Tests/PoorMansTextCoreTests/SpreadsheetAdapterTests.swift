import Foundation
import XCTest
@testable import PoorMansTextCore

final class SpreadsheetAdapterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextSpreadsheetTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testODSConversionPreservesSheetsValuesAndSourceBytes() throws {
        let sourceURL = fixture("multisheet.ods")
        let sourceBefore = try Data(contentsOf: sourceURL)
        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("ods-result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(result.format, .ods)
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: "## Sheet: Summary")).lowerBound,
            try XCTUnwrap(markdown.range(of: "## Sheet: Details & Notes")).lowerBound
        )
        XCTAssertTrue(markdown.contains("| Äpfel | 12 | 1,50 |"))
        XCTAssertTrue(markdown.contains("| Total | 39 | 41,75 |"))
        XCTAssertTrue(markdown.contains("First line<br>Second line"))
        XCTAssertTrue(markdown.contains(#"Contains a \| pipe and a tab"# + "\tinside"))
        XCTAssertTrue(markdown.contains("Grüße aus Köln"))
        let dataRows = markdown.split(separator: "\n").filter {
            $0.hasPrefix("| ") && !$0.contains("---")
        }
        XCTAssertEqual(dataRows.count, 9)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
    }

    func testODSTabSeparatedRenderingEscapesCellBoundariesReversibly() throws {
        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: fixture("multisheet.ods"),
                destination: .directory(temporaryDirectory.appendingPathComponent("tsv-result")),
                options: ConversionOptions(spreadsheetRendering: .tabSeparated)
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertTrue(markdown.contains("```tsv"))
        XCTAssertTrue(markdown.contains(#"First line\nSecond line"#))
        XCTAssertTrue(markdown.contains(#"a tab\tinside"#))
        XCTAssertTrue(markdown.contains("Contains a | pipe"))
    }

    func testGeneratedODSReportsFlattenedMergeAndMissingFormulaResult() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Generated.ods")
        try ZIPFixtureBuilder.odsPackage(contentXML: generatedODSContent).write(to: sourceURL)

        let inspection = try DocumentConverter().inspect(sourceURL)
        XCTAssertEqual(
            inspection.expectedWarnings.map(\.code),
            ["spreadsheet.mergesFlattened", "spreadsheet.formulaResultMissing"]
        )

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("generated-result"))
            )
        )
        XCTAssertEqual(result.diagnostics.map(\.code), inspection.expectedWarnings.map(\.code))
        XCTAssertTrue(
            try String(contentsOf: result.markdownFile, encoding: .utf8)
                .contains("| Merged |  |")
        )
    }

    func testODSExpansionBudgetRejectsOversizedRepeatedContent() throws {
        for repeated in ["16385", "9223372036854775807"] {
            let oversized = generatedODSContent.replacingOccurrences(
                of: "table:number-columns-spanned=\"2\"",
                with: "table:number-columns-repeated=\"\(repeated)\""
            )
            let sourceURL = temporaryDirectory.appendingPathComponent("Oversized-\(repeated).ods")
            try ZIPFixtureBuilder.odsPackage(contentXML: oversized).write(to: sourceURL)

            XCTAssertThrowsError(try DocumentConverter().inspect(sourceURL)) { error in
                XCTAssertTrue(error.localizedDescription.contains("budget"))
            }
        }
    }

    func testXLSXConversionMatchesIndependentPandocValuesAndSheetOrder() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Generated.xlsx")
        try ZIPFixtureBuilder.xlsxPackage(
            firstSheetXML: firstXLSXSheet,
            secondSheetXML: secondXLSXSheet
        ).write(to: sourceURL)
        let sourceBefore = try Data(contentsOf: sourceURL)

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("xlsx-result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        let direct = try directPandocMarkdown(for: sourceURL)

        XCTAssertEqual(result.format, .xlsx)
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: "## Sheet: Summary")).lowerBound,
            try XCTUnwrap(markdown.range(of: "## Sheet: Details & Notes")).lowerBound
        )
        for value in ["Product", "Äpfel", "Birnen", "19", "A-01", "Grüße aus Köln"] {
            XCTAssertTrue(markdown.contains(value), "Native XLSX output lacks \(value)")
            XCTAssertTrue(direct.contains(value), "Pandoc comparison lacks \(value)")
        }
        XCTAssertTrue(markdown.contains("First line<br>Second line"))
        XCTAssertTrue(markdown.contains(#"Contains a \| pipe"#))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
    }

    func testXLSXReportsMergesAndMissingFormulaResults() throws {
        let merged = firstXLSXSheet.replacingOccurrences(
            of: "</worksheet>",
            with: "<mergeCells count=\"1\"><mergeCell ref=\"A1:B1\"/></mergeCells></worksheet>"
        ).replacingOccurrences(of: "<v>19</v>", with: "")
        let sourceURL = temporaryDirectory.appendingPathComponent("Warnings.xlsx")
        try ZIPFixtureBuilder.xlsxPackage(
            firstSheetXML: merged,
            secondSheetXML: secondXLSXSheet
        ).write(to: sourceURL)

        let inspection = try DocumentConverter().inspect(sourceURL)

        XCTAssertEqual(
            inspection.expectedWarnings.map(\.code),
            ["spreadsheet.mergesFlattened", "spreadsheet.formulaResultMissing"]
        )
    }

    func testXLSXRejectsExternalWorksheetRelationships() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("External.xlsx")
        try ZIPFixtureBuilder.xlsxPackage(
            firstSheetXML: firstXLSXSheet,
            secondSheetXML: secondXLSXSheet,
            secondSheetTargetMode: "External"
        ).write(to: sourceURL)

        XCTAssertThrowsError(try DocumentConverter().inspect(sourceURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("external XLSX relationship"))
        }
    }

    func testXLSXRejectsWorksheetWithAnUnrelatedXMLRoot() throws {
        let unrelated = firstXLSXSheet.replacingOccurrences(
            of: "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
            with: "urn:example:not-a-spreadsheet"
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("WrongRoot.xlsx")
        try ZIPFixtureBuilder.xlsxPackage(
            firstSheetXML: unrelated,
            secondSheetXML: secondXLSXSheet
        ).write(to: sourceURL)

        XCTAssertThrowsError(try DocumentConverter().inspect(sourceURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("worksheet root"))
        }
    }

    func testXLSXExpandedCellBudgetRejectsManySparseRows() throws {
        let rows = (1...31).map {
            #"<row r="\#($0)"><c r="XFD\#($0)"><v>1</v></c></row>"#
        }.joined()
        let oversizedSheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>\(rows)</sheetData>
        </worksheet>
        """
        let sourceURL = temporaryDirectory.appendingPathComponent("Oversized.xlsx")
        try ZIPFixtureBuilder.xlsxPackage(
            firstSheetXML: oversizedSheet,
            secondSheetXML: oversizedSheet
        ).write(to: sourceURL)

        XCTAssertThrowsError(try DocumentConverter().inspect(sourceURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("expanded-cell budget"))
        }
    }

    func testRealXLSMatchesTheIndependentODSWorkbookAndKeepsSourceBytes() throws {
        let xlsURL = fixture("not-word.xls")
        let sourceBefore = try Data(contentsOf: xlsURL)
        let xlsResult = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: xlsURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("xls-result"))
            )
        )
        let odsResult = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: fixture("multisheet.ods"),
                destination: .directory(temporaryDirectory.appendingPathComponent("ods-compare"))
            )
        )
        let xlsMarkdown = try String(contentsOf: xlsResult.markdownFile, encoding: .utf8)
        let odsMarkdown = try String(contentsOf: odsResult.markdownFile, encoding: .utf8)

        XCTAssertEqual(xlsResult.format, .xls)
        XCTAssertEqual(
            xlsResult.diagnostics.map(\.code),
            ["spreadsheet.unsupportedObjects", "legacySpreadsheet.potentialLoss"]
        )
        XCTAssertEqual(normalizedDataLines(xlsMarkdown), normalizedDataLines(odsMarkdown))
        XCTAssertEqual(try Data(contentsOf: xlsURL), sourceBefore)
    }

    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/Spreadsheets")
            .appendingPathComponent(name)
    }

    private func directPandocMarkdown(for sourceURL: URL) throws -> String {
        let outputURL = temporaryDirectory.appendingPathComponent("pandoc-xlsx.md")
        let result = try ProcessRunner.run(
            executable: try PandocTool.resolve(nil),
            arguments: [
                "--from=xlsx", "--to=gfm-raw_html", "--wrap=preserve",
                "--output", outputURL.path, sourceURL.path,
            ],
            currentDirectory: temporaryDirectory
        )
        XCTAssertEqual(result.status, 0, result.standardError)
        return try String(contentsOf: outputURL, encoding: .utf8)
    }

    private func normalizedDataLines(_ markdown: String) -> [String] {
        markdown.split(separator: "\n").map(String.init).filter {
            $0.hasPrefix("| ") && !$0.contains("---")
        }.map {
            $0.replacingOccurrences(of: "1,50", with: "1.5")
                .replacingOccurrences(of: "2,25", with: "2.25")
                .replacingOccurrences(of: "0,40", with: "0.4")
                .replacingOccurrences(of: "41,75", with: "41.75")
                .replacingOccurrences(of: "WAHR", with: "TRUE")
                .replacingOccurrences(of: "FALSCH", with: "FALSE")
        }
    }

    private var generatedODSContent: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet>
            <table:table table:name="Generated">
              <table:table-row>
                <table:table-cell table:number-columns-spanned="2" office:value-type="string">
                  <text:p>Merged</text:p>
                </table:table-cell>
                <table:covered-table-cell/>
              </table:table-row>
              <table:table-row>
                <table:table-cell table:formula="of:=1+1" office:value-type="float"/>
              </table:table-row>
            </table:table>
          </office:spreadsheet></office:body>
        </office:document-content>
        """
    }


    private var firstXLSXSheet: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>12</v></c></row>
            <row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><v>7</v></c></row>
            <row r="4"><c r="A4" t="inlineStr"><is><t>Total</t></is></c><c r="B4"><f>SUM(B2:B3)</f><v>19</v></c></row>
          </sheetData>
        </worksheet>
        """
    }

    private var secondXLSXSheet: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="s"><v>4</v></c><c r="B1" t="s"><v>5</v></c></row>
            <row r="2"><c r="A2" t="s"><v>6</v></c><c r="B2" t="inlineStr"><is><t>First line&#10;Second line</t></is></c></row>
            <row r="3"><c r="A3" t="s"><v>7</v></c><c r="B3" t="inlineStr"><is><t>Contains a | pipe&#9;inside</t></is></c></row>
          </sheetData>
        </worksheet>
        """
    }
}
