import Foundation
final class Token: @unchecked Sendable { let lock=NSLock(); var cancelled=false; func cancel(){lock.withLock{cancelled=true}}; func check() throws {if lock.withLock({cancelled}){throw CancellationError()}} }
enum ConversionExecution { struct Context: Sendable { let cancellation: Token }; @TaskLocal static var current: Context?; static func check() throws {try current?.cancellation.check()};static var isCancelled: Bool {current?.cancellation.lock.withLock{current!.cancellation.cancelled} ?? false} }
/// Die synchrone öffentliche Konvertierung darf auch auf Swifts begrenztem
/// Threadpool laufen. Ihre asynchrone Vision-Arbeit erhält deshalb einen eigenen
/// Thread-Executor; auch eine GCD-Queue könnte hinter blockierten Pool-Workern
/// warten. Der eine eigene Thread schläft, solange keine Fortsetzung ansteht.
enum OCRAsyncBridge {
    private final class Executor: TaskExecutor, @unchecked Sendable {
        static let shared = Executor()
        private let condition = NSCondition()
        private var jobs: [UnownedJob] = []
        private init() {
            let thread = Thread { [self] in work() }
            thread.name = "Poor Man's Text document OCR"
            thread.start()
        }
        func enqueue(_ job: consuming ExecutorJob) {
            condition.lock()
            jobs.append(UnownedJob(job))
            condition.signal()
            condition.unlock()
        }
        private func work() {
            while true {
                condition.lock()
                while jobs.isEmpty { condition.wait() }
                let job = jobs.removeFirst()
                condition.unlock()
                job.runSynchronously(on: asUnownedTaskExecutor())
            }
        }
    }

    private final class Completion<Value: Sendable>: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Swift.Result<Value, Error>?
        func finish(_ value: Swift.Result<Value, Error>) {
            lock.withLock { result = value }
            semaphore.signal()
        }
        func get() throws -> Value { try lock.withLock { try result!.get() } }
    }

    static func run<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
        try ConversionExecution.check()
        let context = ConversionExecution.current
        let completion = Completion<Value>()
        let task = Task.detached(executorPreference: Executor.shared) {
            do {
                let value = try await ConversionExecution.$current.withValue(context) { try await operation() }
                completion.finish(.success(value))
            } catch { completion.finish(.failure(error)) }
        }
        while completion.semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            if ConversionExecution.isCancelled || Task.isCancelled { task.cancel() }
        }
        // Erst nach dem tatsächlichen Ende dürfen Gate und temporäre Dateien
        // freigegeben werden. Aktive Vision-Aufrufe haben keine harte Frist.
        try ConversionExecution.check()
        try Task.checkCancellation()
        return try completion.get()
    }
}

import Foundation

/// Vision arbeitet pro Prozess an genau einem Bild. Wartende Dokumente prüfen
/// ihren Abbruch alle 50 ms; normale Dokumentarbeit braucht diesen Slot nicht.
final class OCRConcurrencyGate: @unchecked Sendable {
    static let shared = OCRConcurrencyGate()
    private let condition = NSCondition()
    private var occupied = false
    func withAsyncPermit<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        while true {
            try Task.checkCancellation()
            try ConversionExecution.check()
            if condition.withLock({
                guard !occupied else { return false }
                occupied = true
                return true
            }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { release() }
        try Task.checkCancellation()
        try ConversionExecution.check()
        return try await body()
    }

    private func release() {
        condition.lock(); occupied = false; condition.broadcast(); condition.unlock()
    }
    func withPermit<T>(cancellation: Token? = ConversionExecution.current?.cancellation, _ body: () throws -> T) throws -> T {
        condition.lock()
        do {
            while occupied {
                try cancellation?.check()
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            try cancellation?.check()
            occupied = true
            condition.unlock()
        } catch { condition.unlock(); throw error }
        defer { release() }
        try cancellation?.check()
        return try body()
    }
}

@main struct Probe {
 static func main() async throws {
 let n=Int(CommandLine.arguments.dropFirst().first ?? "24")!;let gate=OCRConcurrencyGate()
 let total=try await withThrowingTaskGroup(of:Int.self){group in
 for index in 0..<n { group.addTask { let token=Token();return try ConversionExecution.$current.withValue(.init(cancellation:token)){try OCRAsyncBridge.run { precondition(ConversionExecution.current?.cancellation === token);return try await gate.withAsyncPermit { if CommandLine.arguments.contains("callback") { await withCheckedContinuation { continuation in
 let thread=Thread { Thread.sleep(forTimeInterval:0.002);continuation.resume() };thread.start()
 } } else if !CommandLine.arguments.contains("immediate") { try await Task.sleep(for:.milliseconds(2)) };return index } }} } }
 var sum=0;for try await value in group {sum+=value};return sum
 };precondition(total==n*(n-1)/2);print("PASS count=\(n) sum=\(total)")
 }
}
