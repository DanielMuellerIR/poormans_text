import Foundation
import XCTest
@testable import CoreProbe
final class StructuredOCRTests: XCTestCase, @unchecked Sendable {
    func testBridgeCancellationReleasesWaiterAndPreservesNextPermit() async throws {
        let gate = OCRConcurrencyGate()
        let entered = expectation(description: "Gate holder entered")
        let released = expectation(description: "Gate holder released")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? gate.withPermit {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            released.fulfill()
        }
        defer { release.signal() }
        await fulfillment(of: [entered], timeout: 2)
        let token = ConversionCancellationToken()
        let waiterStarted = expectation(description: "Bridge task started")
        let task = Task.detached {
            try ConversionExecution.$current.withValue(.init(cancellation: token, progress: nil, processTimeout: nil)) {
                try OCRAsyncBridge.run {
                    waiterStarted.fulfill()
                    return try await gate.withAsyncPermit { XCTFail("Cancelled waiter entered OCR"); return 0 }
                }
            }
        }
        await fulfillment(of: [waiterStarted], timeout: 2)
        token.cancel()
        do { _ = try await task.value; XCTFail("Cancelled conversion succeeded") }
        catch { guard case ConversionError.cancelled = error else { return XCTFail("\(error)") } }
        release.signal()
        await fulfillment(of: [released], timeout: 2)
        let next = try await gate.withAsyncPermit { 42 }
        XCTAssertEqual(next, 42)
    }

    func testSynchronousBridgeRunsFromCooperativeTasksAndPropagatesContext() async throws {
        let total = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let token = ConversionCancellationToken()
                    return try ConversionExecution.$current.withValue(.init(cancellation: token, progress: nil, processTimeout: nil)) {
                        try OCRAsyncBridge.run {
                            XCTAssertTrue(ConversionExecution.current?.cancellation === token)
                            // Vision liefert seine Fortsetzung extern. Task.sleep erzeugt
                            // dagegen einen zusätzlichen Wake-Task auf dem globalen Pool;
                            // dieser kann bei 24 synchron wartenden Callern verhungern.
                            await Self.externalRecognitionCallback()
                            XCTAssertTrue(ConversionExecution.current?.cancellation === token)
                            return index
                        }
                    }
                }
            }
            var sum = 0
            for try await value in group { sum += value }
            return sum
        }
        XCTAssertEqual(total, 276)
    }

    func testCooperativeBridgeSerializesExternalRecognitionCallbacks() async throws {
        let gate = OCRConcurrencyGate()
        let activity = RecognitionActivity()
        let total = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<24 {
                group.addTask {
                    try OCRAsyncBridge.run {
                        try await gate.withAsyncPermit {
                            activity.enter()
                            defer { activity.leave() }
                            await Self.externalRecognitionCallback()
                            return index
                        }
                    }
                }
            }
            var sum = 0
            for try await value in group { sum += value }
            return sum
        }
        XCTAssertEqual(total, 276)
        XCTAssertEqual(activity.maximum, 1)
        XCTAssertEqual(activity.completed, 24)
    }

    private static func externalRecognitionCallback() async {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                Thread.sleep(forTimeInterval: 0.002)
                continuation.resume()
            }
            thread.name = "Poor Man's Text synthetic OCR callback"
            thread.start()
        }
    }

    private final class RecognitionActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var maximumActive = 0
        private var completions = 0
        var maximum: Int { lock.withLock { maximumActive } }
        var completed: Int { lock.withLock { completions } }
        func enter() { lock.withLock { active += 1; maximumActive = max(maximumActive, active) } }
        func leave() { lock.withLock { active -= 1; completions += 1 } }
    }

}
