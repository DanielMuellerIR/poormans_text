import Foundation
import XCTest
@testable import PoorMansTextCore

final class SpreadsheetBudgetTests: XCTestCase {
    func testXLSXHyperlinkGapsConsumeTheSharedCellBudget() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: source) }
        func sheet(_ row: Int, data: String = "") -> String {
            "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(data)</sheetData><hyperlinks><hyperlink ref=\"A\(row)\" display=\"TOKEN\"/></hyperlinks></worksheet>"
        }
        for row in [7, 10] {
            let bytes = try ZIPFixtureBuilder.xlsxPackage(firstSheetXML: sheet(row), secondSheetXML: sheet(row))
            try bytes.write(to: source)
            if row == 7 {
                let value = try XLSXWorkbookParser.parse(packageAt: source, maximumCells: 15)
                XCTAssertEqual(value.sheets.map { $0.rows.count }, [7, 7])
            } else {
                XCTAssertThrowsError(try XLSXWorkbookParser.parse(packageAt: source, maximumCells: 15)) { error in
                    XCTAssertEqual(error.localizedDescription, SpreadsheetLimits.cellBudgetMessage)
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testXLSXEmptyRowsAreChargedOnceWhenFilledByHyperlinks() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: source) }
        let xml = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"10\"/></sheetData><hyperlinks><hyperlink ref=\"A1\" display=\"TOKEN\"/></hyperlinks></worksheet>"
        let empty = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData/></worksheet>"
        try ZIPFixtureBuilder.xlsxPackage(firstSheetXML: xml, secondSheetXML: empty).write(to: source)
        XCTAssertNoThrow(try XLSXWorkbookParser.parse(packageAt: source, maximumCells: 10))
        XCTAssertThrowsError(try XLSXWorkbookParser.parse(packageAt: source, maximumCells: 9))
    }

    func testXLSDenseRowsChargeEmptyGapsBeforeMaterialization() throws {
        let cells = [9: [0: SpreadsheetCell(value: .string("TOKEN"), displayText: "TOKEN", formula: nil)]]
        let value = try LegacyXLSWorkbookParser.BIFFParser.denseRows(cells, maximumCells: 10)
        XCTAssertEqual(value.expandedCellCount, 10)
        XCTAssertEqual(value.rows.count, 10)
        XCTAssertThrowsError(try LegacyXLSWorkbookParser.BIFFParser.denseRows(cells, maximumCells: 9)) { error in
            XCTAssertEqual(error.localizedDescription, SpreadsheetLimits.cellBudgetMessage)
        }
    }
    private func workbook(rows: [[SpreadsheetCell]]) -> SpreadsheetWorkbook {
        SpreadsheetWorkbook(sheets: [SpreadsheetSheet(name: "Data", rows: rows)])
    }

    func testSelectedRowAndCellBoundaryAndNextSheet() throws {
        let row = [SpreadsheetCell](repeating: .empty, count: 10)
        let rows = [[SpreadsheetCell]](repeating: row, count: SpreadsheetLimits.maximumRows)
        var value = workbook(rows: rows)
        XCTAssertEqual(rows.count * row.count, SpreadsheetLimits.maximumCells)
        XCTAssertNoThrow(try SpreadsheetLimits.validate(value))
        value.sheets.append(SpreadsheetSheet(name: "Next", rows: [[.empty]]))
        XCTAssertThrowsError(try SpreadsheetLimits.validate(value)) { error in
            XCTAssertEqual(error.localizedDescription, SpreadsheetLimits.cellBudgetMessage)
        }
    }

    func testRendererRejectsNextRowForBothStyles() throws {
        let value = workbook(rows: [[SpreadsheetCell]](repeating: [], count: SpreadsheetLimits.maximumRows + 1))
        for style in [SpreadsheetRendering.markdownTable, .tabSeparated] {
            XCTAssertThrowsError(try SpreadsheetMarkdownRenderer.render(value, sourceURL: URL(fileURLWithPath: "input.csv"), style: style)) { error in
                XCTAssertEqual(error.localizedDescription, SpreadsheetLimits.rowBudgetMessage)
            }
        }
    }

    func testRendererChargesPaddingEvenWhenMostRowsAreEmpty() throws {
        let width = SpreadsheetLimits.maximumColumns
        let count = SpreadsheetLimits.maximumCells / width
        var rows = [[SpreadsheetCell]](repeating: [], count: count)
        rows[0] = [SpreadsheetCell](repeating: .empty, count: width)
        XCTAssertNoThrow(try SpreadsheetLimits.validate(workbook(rows: rows)))
        rows.append([])
        for style in [SpreadsheetRendering.markdownTable, .tabSeparated] {
            XCTAssertThrowsError(try SpreadsheetMarkdownRenderer.render(workbook(rows: rows), sourceURL: URL(fileURLWithPath: "input.ods"), style: style)) { error in
                XCTAssertEqual(error.localizedDescription, SpreadsheetLimits.cellBudgetMessage)
            }
        }
    }

    func testCSVAndWorkbookHaveIdenticalBudgetErrors() throws {
        let csv = String(repeating: "X\n", count: SpreadsheetLimits.maximumRows + 1)
        XCTAssertThrowsError(try DelimitedTextParser.parse(csv, delimiter: ",")) { error in
            XCTAssertEqual(error.localizedDescription, SpreadsheetLimits.rowBudgetMessage)
        }
        XCTAssertEqual(DelimitedTextLimits.maximumRows, SpreadsheetLimits.maximumRows)
        XCTAssertEqual(DelimitedTextLimits.maximumCells, SpreadsheetLimits.maximumCells)
    }

    func testColumnBoundaryAndBeyondForBothRenderingStyles() throws {
        let columns = SpreadsheetLimits.maximumColumns
        XCTAssertNoThrow(try SpreadsheetLimits.validate(workbook(rows: [[SpreadsheetCell](repeating: .empty, count: columns)])))
        let value = workbook(rows: [[SpreadsheetCell](repeating: .empty, count: columns + 1)])
        for style in [SpreadsheetRendering.markdownTable, .tabSeparated] {
            XCTAssertThrowsError(try SpreadsheetMarkdownRenderer.render(value, sourceURL: URL(fileURLWithPath: "input.xlsx"), style: style)) { error in
                XCTAssertEqual(error.localizedDescription, SpreadsheetLimits.columnBudgetMessage)
            }
        }
    }
}
