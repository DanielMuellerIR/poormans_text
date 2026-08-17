import Foundation
import XCTest
@testable import PoorMansTextCore

/// Regressionstests zu den Funden des Nacht-Reviews vom 2026-08-17.
final class ReviewFixes20260817Tests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextReviewFixes-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - TSV-Vorlauf bleibt im Budget

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

    // MARK: - Staging öffnet die Quelle genau einmal

    func testStagingRejectsASourceThatExceedsTheBudget() throws {
        let source = temporaryDirectory.appendingPathComponent("gross.bin")
        try Data(repeating: 0x41, count: 4096).write(to: source)
        let destination = temporaryDirectory.appendingPathComponent("staged.bin")

        XCTAssertThrowsError(
            try VerifiedFileStaging.stage(
                from: source,
                to: destination,
                maximumBytes: 1024,
                describedAs: "the source"
            )
        )
        // Kein halbfertiger Rest: Das Budget wird vor dem ersten Schreiben geprüft.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testStagingRejectsADirectoryInsteadOfCopyingIt() throws {
        let source = temporaryDirectory.appendingPathComponent("ordner", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let destination = temporaryDirectory.appendingPathComponent("staged-dir")

        XCTAssertThrowsError(
            try VerifiedFileStaging.stage(
                from: source,
                to: destination,
                maximumBytes: 1_048_576,
                describedAs: "the source"
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("regular file"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testStagingNeverOverwritesAnExistingDestination() throws {
        let source = temporaryDirectory.appendingPathComponent("quelle.bin")
        try Data("neu".utf8).write(to: source)
        let destination = temporaryDirectory.appendingPathComponent("staged.bin")
        try Data("bestehend".utf8).write(to: destination)

        XCTAssertThrowsError(
            try VerifiedFileStaging.stage(
                from: source,
                to: destination,
                maximumBytes: 1_048_576,
                describedAs: "the source"
            )
        )
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "bestehend")
    }

    func testStagingCopiesAValidSourceCompletely() throws {
        let payload = Data(repeating: 0x5A, count: 300_000)   // größer als ein Lesepuffer
        let source = temporaryDirectory.appendingPathComponent("quelle.bin")
        try payload.write(to: source)
        let destination = temporaryDirectory.appendingPathComponent("staged.bin")

        let copied = try VerifiedFileStaging.stage(
            from: source,
            to: destination,
            maximumBytes: 1_048_576,
            describedAs: "the source"
        )

        XCTAssertEqual(copied, payload.count)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }
}
