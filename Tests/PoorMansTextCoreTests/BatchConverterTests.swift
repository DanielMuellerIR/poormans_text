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
        let slowEntered = DispatchSemaphore(value: 0)
        let fastFinished = DispatchSemaphore(value: 0)
        let adapter = BatchTestAdapter { context in
            state.enter(context.inputURL.lastPathComponent)
            defer {
                state.leave(context.inputURL.lastPathComponent)
                if context.inputURL == second { fastFinished.signal() }
            }
            if context.inputURL == first {
                slowEntered.signal()
                XCTAssertEqual(fastFinished.wait(timeout: .now() + 10), .success)
            } else {
                XCTAssertEqual(slowEntered.wait(timeout: .now() + 10), .success)
            }
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

    /// Die Reservierung kannte bisher nur den Test mit ZWEIMAL demselben Ziel.
    /// Damit blieben beide Präfixzweige und die Schreibweisen-Normalisierung
    /// ungeprüft — ein verschachteltes Ziel oder eines, das sich nur in der
    /// Groß-/Kleinschreibung unterscheidet, hätte still durchgehen können
    /// (Review-Fund 2026-09-10).
    func testNestedAndCaseOnlyDifferentOutputsAreReserved() throws {
        let first = try source("aussen"), second = try source("innen"), third = try source("gross")
        let state = Activity()
        let converter = BatchConverter(converter: DocumentConverter(adapters: [BatchTestAdapter { context in
            state.enter(context.inputURL.lastPathComponent)
            state.leave(context.inputURL.lastPathComponent)
        }]))
        let output = root.appendingPathComponent("Ziel")
        let results = try converter.convert([
            ConversionRequest(inputURL: first, destination: .directory(output)),
            ConversionRequest(inputURL: second, destination: .directory(output.appendingPathComponent("Unter"))),
            ConversionRequest(inputURL: third, destination: .directory(root.appendingPathComponent("ZIEL"))),
        ], jobs: 1)

        XCTAssertNoThrow(try results[0].outcome.get())
        for index in [1, 2] {
            XCTAssertThrowsError(try results[index].outcome.get()) { error in
                guard case ConversionError.outputAlreadyExists = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(state.started, [first.lastPathComponent])
    }

    /// `prepareParent` prüft vor jedem Dokument alle Quellschnappschüsse neu.
    /// Kein Test hatte diese Prüfung je ausgelöst.
    func testASourceRepointedAfterPlanningIsRejected() throws {
        let first = try source("erste"), decoy = try source("koeder")
        let link = root.appendingPathComponent("verweis.batch")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let converter = BatchConverter(converter: DocumentConverter(adapters: [BatchTestAdapter { context in
            guard context.inputURL == first else { return }
            // Während das erste Dokument läuft, zeigt der Verweis plötzlich woandershin.
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: decoy)
        }]))
        let results = try converter.convert(
            [ConversionRequest(inputURL: first), ConversionRequest(inputURL: link)], jobs: 1
        )

        XCTAssertNoThrow(try results[0].outcome.get())
        XCTAssertThrowsError(try results[1].outcome.get()) { error in
            guard case ConversionError.fileSystemFailure(let reason) = error else {
                return XCTFail("\(error)")
            }
            // Genau die Planungsschicht muss greifen, nicht erst die
            // Schwesterprüfung im Konverter ("the batch source changed …").
            XCTAssertEqual(reason, "a batch source changed after output planning")
        }
        // Der untergeschobene Köder wurde nicht angefasst.
        XCTAssertEqual(try Data(contentsOf: decoy), Data("koeder".utf8))
    }

    /// Ein gemeinsamer Zielordner, der schon als DATEI existiert, muss den
    /// ganzen Lauf abweisen, bevor irgendein Worker startet.
    func testAnOutputRootThatIsAlreadyAFileRejectsTheWholeRun() throws {
        let first = try source("eins")
        let rootFile = root.appendingPathComponent("Ergebnis")
        try Data("belegt".utf8).write(to: rootFile)
        let state = Activity()
        let converter = BatchConverter(converter: DocumentConverter(adapters: [BatchTestAdapter { context in
            state.enter(context.inputURL.lastPathComponent)
            state.leave(context.inputURL.lastPathComponent)
        }]))

        XCTAssertThrowsError(
            try converter.convert(
                [ConversionRequest(inputURL: first, destination: .directory(rootFile.appendingPathComponent("a")))],
                outputRoots: [rootFile]
            )
        ) { error in
            guard case ConversionError.outputAlreadyExists = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(state.started, [])
        XCTAssertEqual(try Data(contentsOf: rootFile), Data("belegt".utf8))
    }

    /// Der Fortschritt läuft auf Worker-Threads. Bisher las kein Test `sequence`,
    /// `running` oder `documentProgress`, die Sperren im Zustand waren also nie
    /// über ihre Zusicherungen geprüft.
    func testBatchProgressStaysConsistentAcrossWorkers() throws {
        let sources = try (0..<3).map { try source("dok\($0)") }
        let rendezvous = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let converter = BatchConverter(converter: DocumentConverter(adapters: [BatchTestAdapter { context in
            guard context.inputURL != sources[2] else { return }
            rendezvous.signal()
            _ = release.wait(timeout: .now() + 2)
        }]))
        let events = EventLog()
        DispatchQueue.global().async {
            // Erst weiterlaufen lassen, wenn wirklich zwei Worker gleichzeitig stehen.
            _ = rendezvous.wait(timeout: .now() + 2)
            _ = rendezvous.wait(timeout: .now() + 2)
            release.signal()
            release.signal()
        }
        let results = try converter.convert(
            sources.map { ConversionRequest(inputURL: $0) },
            jobs: 2,
            progress: { events.append($0) }
        )

        XCTAssertEqual(results.count, 3)
        let sequences = events.all.map(\.sequence)
        XCTAssertEqual(sequences.sorted(), Array(1...sequences.count), "Sequenz eindeutig und lückenlos; Zustellung darf parallel erfolgen")
        XCTAssertEqual(events.all.filter { $0.result != nil }.count, 3)
        XCTAssertTrue(events.all.contains { $0.running.count == 2 }, "zwei Worker gleichzeitig sichtbar")
        for event in events.all {
            XCTAssertEqual(event.running, event.running.sorted())
            XCTAssertLessThanOrEqual(event.completed, event.total)
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

/// Sammelt Batch-Ereignisse threadsicher; der Callback läuft auf Worker-Threads.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BatchConversionProgress] = []
    var all: [BatchConversionProgress] { lock.withLock { events } }
    func append(_ event: BatchConversionProgress) { lock.withLock { events.append(event) } }
}
