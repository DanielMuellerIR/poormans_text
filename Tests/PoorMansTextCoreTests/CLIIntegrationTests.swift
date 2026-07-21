import Foundation
import XCTest
@testable import PoorMansTextCore

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
        XCTAssertTrue(success.standardError.isEmpty)
        let successJSON = try decodeJSON(success.standardOutput)
        XCTAssertEqual(
            Set(successJSON.keys),
            ["assets", "input", "markdownFile", "ok", "outputDirectory", "version", "warnings"]
        )
        XCTAssertEqual(successJSON["ok"] as? Bool, true)
        XCTAssertEqual(successJSON["version"] as? String, ProductInfo.version)
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
        XCTAssertEqual(Set(failureJSON.keys), ["error", "ok", "version"])
        XCTAssertEqual(failureJSON["ok"] as? Bool, false)
        XCTAssertNotNil(failureJSON["error"] as? String)
    }

    func testJSONFailureExitCodeMatrixRemainsStable() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLIExitTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try assertJSONFailure(["--json", "--unknown"], expectedStatus: 64)
        try assertJSONFailure(
            ["--json", temporaryDirectory.appendingPathComponent("Missing.rtf").path],
            expectedStatus: 66
        )

        let validInput = try FixtureFactory.createMinimalRTF(in: temporaryDirectory)
        try assertJSONFailure(
            [
                "--json",
                "--pandoc", temporaryDirectory.appendingPathComponent("missing-pandoc").path,
                validInput.path,
            ],
            expectedStatus: 69
        )

        let existingOutput = temporaryDirectory.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingOutput, withIntermediateDirectories: false)
        try assertJSONFailure(
            ["--json", "--output", existingOutput.path, validInput.path],
            expectedStatus: 73
        )

        let failingPandoc = temporaryDirectory.appendingPathComponent("failing-pandoc")
        try Data("#!/bin/sh\nexit 42\n".utf8).write(to: failingPandoc)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: failingPandoc.path
        )
        try assertJSONFailure(
            ["--json", "--pandoc", failingPandoc.path, validInput.path],
            expectedStatus: 70
        )

        let unreadableInput = try FixtureFactory.createMinimalRTF(
            in: temporaryDirectory,
            name: "Unreadable.rtf"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadableInput.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unreadableInput.path
            )
        }
        try assertJSONFailure(["--json", unreadableInput.path], expectedStatus: 74)
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

    private func assertJSONFailure(
        _ arguments: [String],
        expectedStatus: Int32
    ) throws {
        let result = try runCLI(arguments)
        XCTAssertEqual(result.status, expectedStatus, result.standardError)
        XCTAssertTrue(result.standardError.isEmpty)
        let json = try decodeJSON(result.standardOutput)
        XCTAssertEqual(Set(json.keys), ["error", "ok", "version"])
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["version"] as? String, ProductInfo.version)
        XCTAssertNotNil(json["error"] as? String)
    }

    private struct CLIProcessResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }
}
