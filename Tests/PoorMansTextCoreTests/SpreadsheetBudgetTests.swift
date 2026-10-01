import Foundation
import XCTest
@testable import PoorMansTextCore

final class SpreadsheetBudgetTests: XCTestCase {
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
