import AppKit
import Darwin
import XCTest
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class ConversionCancellationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Cancellation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCancelAtPublishingLeavesSourceAndNoOutputOrWorkspace() throws {
        let source = root.appendingPathComponent("source.csv")
        let data = Data("Name,Value\nAlpha,42\nBeta,57\n".utf8)
        try data.write(to: source)
        let token = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source), progress: {
            if $0.phase == .publishing { token.cancel() }
        }, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.csv"])
    }

    func testNestedConversionPreservesTheDocumentTimeoutReason() throws {
        let source = root.appendingPathComponent("nested.csv")
        try Data("Name,Value\nAlpha,42\n".utf8).write(to: source)
        let token = ConversionCancellationToken()
        let context = ConversionExecution.Context(cancellation: token, progress: { value in
            if value.phase == .publishing {
                ConversionExecution.current?.cancellation.stop(.processTimedOut)
            }
        }, processTimeout: nil)
        XCTAssertThrowsError(try ConversionExecution.$current.withValue(context) {
            try DocumentConverter().convert(ConversionRequest(inputURL: source))
        }) { error in
            guard case ConversionError.processTimedOut = error else { return XCTFail("\(error)") }
        }
        // Derselbe Kontext erlaubt dem äußeren Adapter, einen umformulierten
        // Parserfehler wieder als Dokumenttimeout weiterzugeben.
        XCTAssertThrowsError(try token.checkCancellation()) { error in
            guard case ConversionError.processTimedOut = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentConverter.defaultOutputDirectory(for: source).path))
    }

    func testCancelAfterPublicationRetainsCommittedResult() throws {
        let source = root.appendingPathComponent("source.csv")
        try Data("Name,Value\nAlpha,42\n".utf8).write(to: source)
        let token = ConversionCancellationToken()
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source), progress: {
            if $0.phase == .finished { token.cancel() }
        }, cancellation: token)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.markdownFile.path))
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("Alpha"))
    }

    func testRealRTFDCancelBeforePublishCleansAssets() throws {
        guard ExternalToolResolver().isAvailable(.pandoc) else { throw XCTSkip("Pandoc unavailable") }
        let source = try FixtureFactory.createRichRTFD(in: root)
        let filesBefore = try source.packageURL.subpathsOfRegularFiles()
        let token = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source.packageURL), progress: {
            if $0.phase == .publishing { token.cancel() }
        }, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try source.packageURL.subpathsOfRegularFiles(), filesBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentConverter.defaultOutputDirectory(for: source.packageURL).path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans") })
    }

    func testTimeoutKillsIgnoringProcessAndDoesNotCancelParentToken() throws {
        let token = ConversionCancellationToken()
        let folder = try XCTUnwrap(root)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                _ = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "trap '' TERM; echo $$ > pid; while :; do :; done"],
                    currentDirectory: folder, timeout: 0.1, cancellation: token, terminationGrace: 0.05)
                XCTFail("Tool did not time out")
            } catch {
                guard case ConversionError.processTimedOut = error else { return XCTFail("\(error)") }
            }
        }
        let status = finished.wait(timeout: .now() + 3)
        let pid = try Int32(String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        if status == .timedOut, let pid { kill(pid, SIGKILL) }
        XCTAssertEqual(status, .success)
        if let pid { XCTAssertEqual(kill(pid, 0), -1) }
        XCTAssertFalse(token.isCancelled)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".process-") })
    }

    func testTimeoutAlsoStopsAChildInTheOwnedProcessGroup() throws {
        let folder = try XCTUnwrap(root)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                _ = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "echo $$ > pid; trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do echo x >> heartbeat; sleep 0.02; done' & wait"],
                    currentDirectory: folder, timeout: 0.2, terminationGrace: 0.05)
                XCTFail("Tool did not time out")
            } catch {
                guard case ConversionError.processTimedOut = error else { return XCTFail("\(error)") }
            }
        }
        let status = finished.wait(timeout: .now() + 3)
        if status == .timedOut {
            let pid = try Int32(String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            if let pid { kill(-pid, SIGKILL) }
        }
        XCTAssertEqual(status, .success)
        let heartbeat = folder.appendingPathComponent("heartbeat")
        let before = try Data(contentsOf: heartbeat)
        XCTAssertFalse(before.isEmpty)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(try Data(contentsOf: heartbeat), before, "Child kept writing after timeout")
    }

    func testProcessOutputLimitFailsWithoutLeavingCaptureFiles() throws {
        XCTAssertThrowsError(try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '01234567890123456789'"], currentDirectory: root,
            captureStandardOutput: true, maximumCapturedBytes: 10))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    @MainActor
    func testCancelledClipboardConversionLeavesPasteboardUntouched() async throws {
        let model = AppModel(defaults: .isolatedForAppTest())
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep original", forType: .string)
        model.convertRichText(RichTextClipboard.Source(kind: .rtf, data: Data(#"{\rtf1 Original text}"#.utf8)), to: pasteboard)
        model.cancelConversion()
        let deadline = Date().addingTimeInterval(3)
        while model.isConverting && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isConverting)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep original")
        guard case .failed(_, let message) = model.state else { return XCTFail("Expected cancelled state") }
        XCTAssertEqual(message, AppErrorMessage.describe(ConversionError.cancelled))
    }

    @MainActor
    func testAppCancelRetainsFinishedBatchAndSkipsRemainingInputs() async throws {
        let first = root.appendingPathComponent("first.csv")
        let second = root.appendingPathComponent("large.csv")
        let third = root.appendingPathComponent("third.csv")
        try Data("Name,Value\nAlpha,42\n".utf8).write(to: first)
        try Data(("Name,Value\n" + String(repeating: "long input value,12345\n", count: 100_000)).utf8).write(to: second)
        try Data("Name,Value\nGamma,57\n".utf8).write(to: third)
        let original = try Data(contentsOf: second)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.convert([first, second, third])
        let deadline = Date().addingTimeInterval(5)
        var cancelled = false
        while model.isConverting && Date() < deadline {
            if case .convertingBatch(let progress) = model.state, progress.finished.count == 1 {
                model.cancelConversion()
                cancelled = true
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(model.isConverting)
        guard case .batchFinished(let items) = model.state else { return XCTFail("Missing batch") }
        XCTAssertEqual(items.map { $0.result != nil }, [true, false, false])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(items[0].result).markdownFile.path))
        XCTAssertEqual(try Data(contentsOf: second), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans") })
        XCTAssertTrue(model.acceptsNewDocuments)
    }
}

private extension URL {
    func subpathsOfRegularFiles() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: self.path) {
            let file = appendingPathComponent(path)
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[path] = try Data(contentsOf: file)
            }
        }
        return result
    }
}
