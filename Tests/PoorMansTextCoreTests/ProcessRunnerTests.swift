import Foundation
import XCTest
@testable import PoorMansTextCore

final class ProcessRunnerTests: XCTestCase {
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
        XCTAssertEqual(result.standardError, "diagnostic\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix(".process-") }
        XCTAssertTrue(leftovers.isEmpty, "Process files remain: \(leftovers)")
    }
}
