import Foundation
import XCTest
@testable import PoorMansTextCore

final class ProcessRunnerTests: XCTestCase {
    func testSuccessfulLeaderDoesNotLeaveBackgroundChildrenRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(/bin/sleep 0.6; echo orphan > child-finished; echo late >&2) & exit 0"],
            currentDirectory: root, timeout: 3)
        XCTAssertEqual(result.status, 0)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("child-finished").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".process-") })
    }

    func testStartupHandshakePreservesLiteralArgumentsAndClosedInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let literal = "quote'\" $HOME $(echo wrong) `echo wrong`"
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "if read -r value; then exit 1; fi; printf '%s' \"$1\"", "test", literal],
            currentDirectory: root, captureStandardOutput: true, timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, literal)
        XCTAssertThrowsError(try ProcessRunner.run(executable: root.appendingPathComponent("missing"),
            arguments: [], currentDirectory: root, timeout: 3))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testDiscardsLargeStandardOutputAndKeepsStandardError() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextProcessRunnerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let executable = temporaryDirectory.appendingPathComponent("noisy-tool")
        try Data(
            "#!/bin/sh\n/bin/dd if=/dev/zero bs=1048576 count=4 2>/dev/null\necho diagnostic >&2\nexit 42\n".utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let result = try ProcessRunner.run(
            executable: executable,
            arguments: [],
            currentDirectory: temporaryDirectory
        )

        XCTAssertEqual(result.status, 42)
        XCTAssertTrue(result.standardOutput.isEmpty)
        XCTAssertEqual(result.standardError, "diagnostic\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix(".process-") }
        XCTAssertTrue(leftovers.isEmpty, "Process files remain: \(leftovers)")
    }

    func testCapturesStandardOutputWithoutUsingAPipe() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextProcessRunnerCaptureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["captured"],
            currentDirectory: temporaryDirectory,
            captureStandardOutput: true
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, "captured\n")
        XCTAssertTrue(result.standardError.isEmpty)
    }
}
