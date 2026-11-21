import Foundation
import XCTest
@testable import PoorMansTextCore

final class SpreadsheetRenderingRegressionTests: XCTestCase {
    func testTabSeparatedRenderingStopsBeforeScanningAHugeRepeatedCell() throws {
        // Der ODS-Parser darf denselben Zelltext über Zeilen- und
        // Spaltenwiederholungen sehr oft referenzieren. Der frühere Vorlauf las
        // ALLE Zellen, bevor der erste begrenzte Append lief — bei 4 MiB je
        // Zelle und 4096 Zellen wären das 16 GiB Zeichenarbeit für eine
        // Ausgabe, die schon nach dem Budget abgelehnt wird.
        let hugeText = String(repeating: "x", count: 4 * 1_024 * 1_024)
        let cell = SpreadsheetCell(value: .string(hugeText), displayText: hugeText, formula: nil)
        let rows = Array(repeating: Array(repeating: cell, count: 64), count: 64)
        let workbook = SpreadsheetWorkbook(sheets: [SpreadsheetSheet(name: "Blatt", rows: rows)])

        let started = Date()
        XCTAssertThrowsError(
            try SpreadsheetMarkdownRenderer.render(
                workbook,
                sourceURL: URL(fileURLWithPath: "/tmp/huge.ods"),
                style: .tabSeparated,
                maximumOutputBytes: 16 * 1_024 * 1_024
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("size limit"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
        // Der Abbruch muss nach wenigen Zellen kommen. Ohne die Begrenzung
        // liefe der Vorlauf über alle 4096 Zellen und bräuchte ein Vielfaches.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testTabSeparatedRenderingStillFencesBackticksInSmallWorkbooks() throws {
        let cell = SpreadsheetCell(value: .string("a ``` b"), displayText: "a ``` b", formula: nil)
        let workbook = SpreadsheetWorkbook(
            sheets: [SpreadsheetSheet(name: "Blatt", rows: [[cell]])]
        )

        let markdown = try SpreadsheetMarkdownRenderer.render(
            workbook,
            sourceURL: URL(fileURLWithPath: "/tmp/small.ods"),
            style: .tabSeparated
        )

        // Der Zaun muss länger sein als die längste Backtick-Folge im Inhalt.
        XCTAssertTrue(markdown.contains("````tsv"), markdown)
    }

    func testSpreadsheetNamesAndLiteralCellsCannotCreateMarkdownResources() throws {
        let cellText = "![Bild](https://host/x) <img src=\"https://host/y\">"
        let workbook = SpreadsheetWorkbook(sheets: [
            SpreadsheetSheet(
                name: "![Blatt](https://host/s)",
                rows: [[SpreadsheetCell(value: .string(cellText), displayText: cellText, formula: nil)]]
            ),
        ])
        let markdown = try SpreadsheetMarkdownRenderer.render(
            workbook,
            sourceURL: URL(fileURLWithPath: "/tmp/![Datei](https-host).xlsx"),
            style: .markdownTable
        )

        XCTAssertFalse(markdown.contains("![Bild]("), markdown)
        XCTAssertFalse(markdown.contains("| <img"), markdown)
        XCTAssertTrue(markdown.contains(#"\<img"#), markdown)
        XCTAssertFalse(markdown.contains("![Blatt]("), markdown)
        XCTAssertTrue(markdown.contains(#"\!\[Bild\]\(https://host/x\)"#), markdown)
    }

    func testSpreadsheetLinkReferencesPreserveLiteralAmpersands() throws {
        let root = try makeRegressionDirectory()
        for target in ["javascript&colon;alert(1)", "java&#x73;cript&colon;alert(1)", "data&colon;text/html,a", "https://example.invalid/?a=1&b=2"] {
            let workbook = SpreadsheetWorkbook(sheets: [.init(name: "S", rows: [[.init(value: .string("CLICKTOKEN"), displayText: "CLICKTOKEN", formula: nil, linkTarget: target)]])])
            let markdown = try SpreadsheetMarkdownRenderer.render(workbook, sourceURL: root.appendingPathComponent("input.ods"), style: .markdownTable)
            XCTAssertTrue(markdown.contains(target.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")), markdown)
        }
    }
}
