import Foundation
import XCTest

final class CLIIntegrationTests: XCTestCase {
    func testRTFSuccessAndInvalidDataKeepJSONAndExitSemantics() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLIIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let validInput = try FixtureFactory.createMinimalRTF(in: temporaryDirectory)
        let success = try runCLI(["--json", validInput.path])
        XCTAssertEqual(success.status, 0, success.standardError)
        let successJSON = try decodeJSON(success.standardOutput)
        XCTAssertEqual(successJSON["ok"] as? Bool, true)
        XCTAssertEqual(successJSON["version"] as? String, "0.4.0")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: temporaryDirectory.appendingPathComponent("Minimal-markdown/Minimal.md").path
            )
        )

        let invalidInput = temporaryDirectory.appendingPathComponent("Invalid.rtf")
        try Data("not rtf".utf8).write(to: invalidInput)
        let failure = try runCLI(["--json", invalidInput.path])
        XCTAssertEqual(failure.status, 65, failure.standardError)
        XCTAssertTrue(failure.standardError.isEmpty)
        let failureJSON = try decodeJSON(failure.standardOutput)
        XCTAssertEqual(failureJSON["ok"] as? Bool, false)
        XCTAssertNotNil(failureJSON["error"] as? String)
    }

    private func runCLI(_ arguments: [String]) throws -> CLIProcessResult {
        let executable = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("poormans-text")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        return CLIProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            standardError: String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private func decodeJSON(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
        )
    }

    private struct CLIProcessResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }
}
