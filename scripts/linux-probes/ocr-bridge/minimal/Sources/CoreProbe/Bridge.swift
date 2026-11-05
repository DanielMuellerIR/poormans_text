import Foundation
enum ConversionError: Error { case cancelled }
final class ConversionCancellationToken: @unchecked Sendable { let lock=NSLock(); var cancelled=false; func cancel(){lock.withLock{cancelled=true}}; func checkCancellation() throws {if lock.withLock({cancelled}){throw ConversionError.cancelled}} }
enum ConversionExecution { struct Context: Sendable { let cancellation: ConversionCancellationToken; let progress: Int?; let processTimeout: Double? }; @TaskLocal static var current: Context?; static func check() throws {try current?.cancellation.checkCancellation()};static var isCancelled: Bool {current?.cancellation.lock.withLock{current!.cancellation.cancelled} ?? false} }
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
