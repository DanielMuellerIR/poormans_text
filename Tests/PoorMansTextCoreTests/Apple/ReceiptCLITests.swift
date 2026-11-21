#if !os(Linux)
import Foundation
import XCTest
@testable import PoorMansTextCore

final class ReceiptCLITests: XCTestCase {
    func testExtractArgumentAndMaskErrorsProduceOneJSONResponse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mask = directory.appendingPathComponent("invalid.json")
        try Data("{".utf8).write(to: mask)

        for arguments in [
            ["extract", "--format", "text", "--mask", mask.path, "input.pdf"],
            ["extract", "--mask", mask.path, "--", "-input.pdf"],
        ] {
            let result = try run(arguments, from: directory)
            XCTAssertEqual(result.status, 2)
            XCTAssertTrue(result.standardError.hasPrefix("Error: "))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: Data(result.standardOutput.utf8)
            ) as? [String: Any])
            XCTAssertFalse(try XCTUnwrap(object["error"] as? String).isEmpty)
            XCTAssertEqual(object["cancelled"] as? Bool, false)
        }
    }

    private func run(_ arguments: [String], from directory: URL) throws -> ProcessResult {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("poormans-text")
        return try ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            currentDirectory: directory,
            captureStandardOutput: true,
            timeout: 15
        )
    }
}
#endif
