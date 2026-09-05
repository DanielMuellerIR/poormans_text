import Foundation
import XCTest
@testable import PoorMansTextCore

final class BatchConverterTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTBatch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func source(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name + ".batch")
        try Data(name.utf8).write(to: url)
        return url
    }
    func testActualParallelismStableOrderAndResultsWithoutCallback() throws {
        let first = try source("slow"), second = try source("fast")
        let state = Activity()
        let adapter = BatchTestAdapter { context in
            state.enter(context.inputURL.lastPathComponent)
            defer { state.leave(context.inputURL.lastPathComponent) }
            if context.inputURL == first { Thread.sleep(forTimeInterval: 0.12) }
            else { Thread.sleep(forTimeInterval: 0.02) }
        }
        let results = try BatchConverter(converter: DocumentConverter(adapters: [adapter])).convert(
            [ConversionRequest(inputURL: first), ConversionRequest(inputURL: second)], jobs: 2)
        XCTAssertEqual(results.map(\.index), [0, 1])
        XCTAssertEqual(results.map(\.inputURL), [first, second])
        XCTAssertEqual(state.maximum, 2)
        XCTAssertEqual(state.finished.first, "fast.batch")
        for result in results { XCTAssertNoThrow(try result.outcome.get()) }
    }
    func testFirstPositionReservesCollisionBeforeEitherWorkerCanRun() throws {
        for slowFirst in [true, false] {
            let first = try source("first\(slowFirst)"), second = try source("second\(slowFirst)")
            let output = root.appendingPathComponent("shared\(slowFirst)")
            let state = Activity()
            let converter = BatchConverter(converter: DocumentConverter(adapters: [BatchTestAdapter { context in
                state.enter(context.inputURL.lastPathComponent); defer { state.leave(context.inputURL.lastPathComponent) }
                if (context.inputURL == first) == slowFirst { Thread.sleep(forTimeInterval: 0.05) }
            }]))
            let results = try converter.convert([ConversionRequest(inputURL: first, destination: .directory(output)), ConversionRequest(inputURL: second, destination: .directory(output))], jobs: 2)
            XCTAssertNoThrow(try results[0].outcome.get())
            XCTAssertThrowsError(try results[1].outcome.get()) { error in
                guard case ConversionError.outputAlreadyExists = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(state.started, [first.lastPathComponent])
        }
    }
    func testWholePlanRejectsExplicitAndAdjacentOutputInsideAnotherSourceBeforeAnyWorker() throws {
        let package = root.appendingPathComponent("source.rtfd")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let inside = package.appendingPathComponent("inside.batch")
        try Data("inside".utf8).write(to: inside)
        let outside = try source("outside")
        for requests in [
            [ConversionRequest(inputURL: outside, destination: .directory(package.appendingPathComponent("new/output"))), ConversionRequest(inputURL: package)],
            [ConversionRequest(inputURL: inside), ConversionRequest(inputURL: package)]
        ] {
            let state = Activity()
            let converter = BatchConverter(converter: DocumentConverter(adapters: [BatchTestAdapter { context in state.enter(context.inputURL.path) }]))
            XCTAssertThrowsError(try converter.convert(requests, jobs: 4)) { error in
                guard case ConversionError.outputInsideInput = error else { return XCTFail("\(error)") }
            }
            XCTAssertTrue(state.started.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.path), ["inside.batch"])
            XCTAssertEqual(try Data(contentsOf: inside), Data("inside".utf8))
        }
    }
    func testCancellationRetainsCommittedResultAndCleansRunningAndUnstartedInputs() throws {
        let inputs = try ["first", "running", "waiting"].map(source)
        let cancellation = ConversionCancellationToken()
        let started = DispatchSemaphore(value: 0)
        let adapter = BatchTestAdapter { context in
            if context.inputURL == inputs[1] {
                started.signal()
                let deadline = Date().addingTimeInterval(2)
                while !cancellation.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
                try ConversionExecution.check()
            }
        }
        let results = try BatchConverter(converter: DocumentConverter(adapters: [adapter])).convert(inputs.map { ConversionRequest(inputURL: $0) }, jobs: 2, cancellation: cancellation, progress: { progress in
            if let result = progress.result, result.index == 0 {
                XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
                cancellation.cancel()
            }
        })
        XCTAssertNoThrow(try results[0].outcome.get())
        for result in results.dropFirst() {
            XCTAssertThrowsError(try result.outcome.get()) { error in
                guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentConverter.defaultOutputDirectory(for: result.inputURL).path))
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
    }
    func testOCRGateSerializesVisionWorkAndCancelsWaitersWithoutEntering() throws {
        let gate = OCRConcurrencyGate()
        let state = Activity()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            try? gate.withPermit {
                state.enter("first"); defer { state.leave("first") }
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let token = ConversionCancellationToken()
        let waiter = DispatchSemaphore(value: 0)
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave(); waiter.signal() }
            do {
                try gate.withPermit(cancellation: token) { state.enter("cancelled waiter") }
                XCTFail("Cancelled OCR waiter entered")
            } catch { }
        }
        token.cancel()
        XCTAssertEqual(waiter.wait(timeout: .now() + 1), .success)
        // Unabhängige Dokumentarbeit braucht keinen Vision-Slot.
        let input = try source("ordinary")
        let result = try BatchConverter(converter: DocumentConverter(adapters: [BatchTestAdapter { _ in }])).convert([ConversionRequest(inputURL: input)])
        XCTAssertNoThrow(try result[0].outcome.get())
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        try gate.withPermit { state.enter("second"); state.leave("second") }
        XCTAssertEqual(state.maximum, 1)
        XCTAssertEqual(state.started, ["first", "second"])
    }
    func testJobsBoundsAndFirstFailureOrder() throws {
        let first = try source("first"), second = try source("second")
        for jobs in [0, 5] { XCTAssertThrowsError(try BatchConverter().convert([], jobs: jobs)) }
        let converter = BatchConverter(converter: DocumentConverter(adapters: [BatchTestAdapter { context in
            if context.inputURL == first { Thread.sleep(forTimeInterval: 0.05); throw ConversionError.processTimedOut }
            throw ConversionError.unsupportedInput(context.inputURL)
        }]))
        let results = try converter.convert([ConversionRequest(inputURL: first), ConversionRequest(inputURL: second)], jobs: 2)
        XCTAssertThrowsError(try results[0].outcome.get()) { error in
            guard case ConversionError.processTimedOut = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try results[1].outcome.get()) { error in
            guard case ConversionError.unsupportedInput = error else { return XCTFail("\(error)") }
        }
    }
}

private struct BatchTestAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors = [SupportedFormat(format: InputFormat(rawValue: "batch"), fileExtensions: ["batch"], containerKind: .file, requiredTools: [])]
    let body: @Sendable (AdapterConversionContext) throws -> Void
    init(_ body: @escaping @Sendable (AdapterConversionContext) throws -> Void) { self.body = body }
    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection { .match(AdapterInputInspection(format: InputFormat(rawValue: "batch"), priority: 1, expectedWarnings: [])) }
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        try body(context)
        try Data(context.inputURL.lastPathComponent.utf8).write(to: context.stagedOutputDirectory.appendingPathComponent("result.md"))
        return StagedConversionResult(markdownRelativePath: "result.md", assetRelativePaths: [], warnings: [])
    }
}
private final class Activity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var starts: [String] = []
    private var ends: [String] = []
    var maximum: Int { lock.withLock { peak } }
    var started: [String] { lock.withLock { starts } }
    var finished: [String] { lock.withLock { ends } }
    func enter(_ name: String) { lock.withLock { starts.append(name); active += 1; peak = max(peak, active) } }
    func leave(_ name: String) { lock.withLock { ends.append(name); active -= 1 } }
}
