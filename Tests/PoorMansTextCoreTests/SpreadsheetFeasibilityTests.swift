import Foundation
import XCTest
@testable import PoorMansTextCore

final class SpreadsheetFeasibilityTests: XCTestCase {
    func testMultiSheetODSFixtureExposesOrderedTablesAndTypedContent() throws {
        let fixtureURL = spreadsheetFixture("multisheet.ods")
        let sourceBefore = try Data(contentsOf: fixtureURL)
        let mimetype = try unzipEntry("mimetype", from: fixtureURL)
        let content = try unzipEntry("content.xml", from: fixtureURL)

        XCTAssertEqual(
            mimetype.trimmingCharacters(in: .whitespacesAndNewlines),
            "application/vnd.oasis.opendocument.spreadsheet"
        )
        let summaryRange = try XCTUnwrap(content.range(of: #"table:name="Summary""#))
        let detailsRange = try XCTUnwrap(
            content.range(of: #"table:name="Details &amp; Notes""#)
        )
        XCTAssertLessThan(summaryRange.lowerBound, detailsRange.lowerBound)
        XCTAssertTrue(content.contains("Äpfel"))
        XCTAssertTrue(content.contains("Grüße aus Köln"))
        XCTAssertTrue(content.contains("table:formula="))

        XCTAssertEqual(try DocumentConverter().detectFormat(at: fixtureURL), .ods)
        XCTAssertEqual(try Data(contentsOf: fixtureURL), sourceBefore)
    }

    private func unzipEntry(_ name: String, from archiveURL: URL) throws -> String {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", archiveURL.path, name],
            currentDirectory: FileManager.default.temporaryDirectory,
            captureStandardOutput: true
        )
        XCTAssertEqual(result.status, 0, result.standardError)
        return result.standardOutput
    }

    private func spreadsheetFixture(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/Spreadsheets")
            .appendingPathComponent(name)
    }
}
