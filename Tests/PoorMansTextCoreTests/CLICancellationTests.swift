import Darwin
import Foundation
import XCTest
@testable import PoorMansTextCore

final class CLICancellationTests: XCTestCase {
    private var root: URL!
    private var cli: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("poormans-text")
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CLICancellation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTimeoutDoesNotPreventTheNextBatchDocument() throws {
        let tool = try slowTool()
        let source = try FixtureFactory.createMinimalRTF(in: root, name: "first.rtf")
        let csv = root.appendingPathComponent("second.csv")
        try Data("Name,Value\nAlpha,42\n".utf8).write(to: csv)
        let result = try ProcessRunner.run(executable: cli,
            arguments: ["--json", "--jobs=2", "--timeout", "0.1", "--pandoc", tool.path, source.path, csv.path],
            currentDirectory: root, captureStandardOutput: true, timeout: 5)
        XCTAssertEqual(result.status, 124, result.standardError)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["ok"] as? Bool }, [false, true])
        XCTAssertTrue(entries[0]["error"] as? String == ConversionError.processTimedOut.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentConverter.defaultOutputDirectory(for: source).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DocumentConverter.defaultOutputDirectory(for: csv).path))
    }

    func testSIGINTAndSIGTERMReturn130AndCleanTheCurrentDocument() throws {
        for signalNumber in [SIGINT, SIGTERM] {
            let tool = try slowTool()
            let source = try FixtureFactory.createMinimalRTF(in: root, name: "signal-\(signalNumber).rtf")
            let original = try Data(contentsOf: source)
            let marker = root.appendingPathComponent("tool.pid")
            try? FileManager.default.removeItem(at: marker)
            let process = Process()
            process.executableURL = cli
            process.arguments = ["--json", "--pandoc", tool.path, source.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            let readyDeadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: marker.path) && process.isRunning && Date() < readyDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let toolPID = try Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            defer { if let toolPID, kill(toolPID, 0) == 0 { kill(-toolPID, SIGKILL) } }
            XCTAssertEqual(kill(process.processIdentifier, signalNumber), 0)
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertFalse(process.isRunning)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 130)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentConverter.defaultOutputDirectory(for: source).path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
        }
    }

    func testProgressStaysOnStandardErrorAndDefaultOutputIsUnchanged() throws {
        let source = root.appendingPathComponent("source.csv")
        try Data("Name,Value\nAlpha,42\n".utf8).write(to: source)
        let result = try ProcessRunner.run(executable: cli,
            arguments: ["--progress", "--json", source.path], currentDirectory: root,
            captureStandardOutput: true, timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.standardError.contains("Progress: source.csv: publishing"))
        XCTAssertTrue(result.standardError.contains("sheet 0/1"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)))
        let markdown = try String(contentsOf: root.appendingPathComponent("source-markdown/source.md"), encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "Alpha").count - 1, 1)
        XCTAssertEqual(markdown.components(separatedBy: "42").count - 1, 1)
    }

    private func slowTool() throws -> URL {
        let tool = root.appendingPathComponent("slow-pandoc")
        // Marker außerhalb des Arbeitsordners; keine benutzerbestimmten Shellwerte.
        try Data("#!/bin/sh\necho $$ > '\(root.path)/tool.pid'\ntrap '' TERM\nwhile :; do sleep 1; done\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }
}
