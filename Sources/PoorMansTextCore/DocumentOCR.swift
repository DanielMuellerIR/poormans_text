import CoreGraphics
import Foundation
import ImageIO

enum DocumentOCR {
    struct FallbackFailure: Error {
        let diagnostic: ConversionWarning
    }
    struct Result: Sendable {
        let structured: StructuredOCRPage?
        let standard: VisionTextRecognition?
        let diagnostics: [ConversionWarning]
        var markdown: String { structured?.markdown ?? MarkdownEscaping.literalBlock(standard?.text ?? "") }
    }

    static func recognize(in image: CGImage, orientation: CGImagePropertyOrientation = .up,
                          languages: [String], method: OCRMethod) throws -> Result {
        try recognize(method: method, structured: {
            guard #available(macOS 26, *) else { throw VisionDocumentRecognizer.RecognitionError.unavailable }
            return try OCRAsyncBridge.run {
                try await VisionDocumentRecognizer.recognize(in: image, orientation: orientation, languages: languages)
            }
        }, standard: {
            try VisionTextRecognizer.recognize(in: image, orientation: orientation, languages: languages)
        })
    }

    static func recognize(method: OCRMethod, structured: () throws -> StructuredDocumentRecognition,
                          standard: () throws -> VisionTextRecognition) throws -> Result {
        try ConversionExecution.check()
        if method == .standard {
            return .init(structured: nil, standard: try standard(), diagnostics: [])
        }
        do {
            let recognition = try structured()
            let page = try StructuredOCRRendering.render(recognition)
            var diagnostics = [ConversionWarning(code: "ocr.structuredApplied", message: "Structured local OCR was used.", kind: .information)]
            if page.flattenedSpans {
                diagnostics.append(.init(code: "ocr.tableSpansFlattened", message: "Merged OCR cells are written once at their upper-left position; covered cells remain empty."))
            }
            return .init(structured: page, standard: nil, diagnostics: diagnostics)
        } catch {
            try ConversionExecution.check()
            if error is CancellationError { throw error }
            if case ConversionError.cancelled = error { throw error }
            let warning = fallbackWarning(for: error)
            do { return .init(structured: nil, standard: try standard(), diagnostics: [warning]) }
            catch {
                try ConversionExecution.check()
                if error is CancellationError { throw error }
                if case ConversionError.cancelled = error { throw error }
                throw FallbackFailure(diagnostic: warning)
            }
        }
    }

    static func fallbackWarning(for error: Error) -> ConversionWarning {
        let reason: String
        switch error {
        case VisionDocumentRecognizer.RecognitionError.unavailable: reason = "Structured OCR requires macOS 26 or later."
        case VisionDocumentRecognizer.RecognitionError.unsupportedLanguages: reason = "The selected language is unavailable for structured OCR."
        case VisionDocumentRecognizer.RecognitionError.inputTooLarge, VisionDocumentRecognizer.RecognitionError.resultTooLarge,
             StructuredOCRRendering.Failure.outputTooLarge: reason = "Structured OCR exceeded its resource limits."
        case StructuredOCRRendering.Failure.insufficientStructure, StructuredOCRRendering.Failure.invalidStructure,
             VisionDocumentRecognizer.RecognitionError.invalidStructure: reason = "The recognized structure could not be reconciled safely with its full text."
        default: reason = "Structured OCR failed."
        }
        return .init(code: "ocr.structuredFallback", message: reason + " Standard local OCR was used instead.")
    }
}

/// Die synchrone öffentliche Konvertierung darf auch auf Swifts begrenztem
/// Threadpool laufen. Ihre asynchrone Vision-Arbeit erhält deshalb einen eigenen
/// Thread-Executor; auch eine GCD-Queue könnte hinter blockierten Pool-Workern
/// warten. Der eine eigene Thread schläft, solange keine Fortsetzung ansteht.
@available(macOS 26, *)
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
                autoreleasepool { job.runSynchronously(on: asUnownedTaskExecutor()) }
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
