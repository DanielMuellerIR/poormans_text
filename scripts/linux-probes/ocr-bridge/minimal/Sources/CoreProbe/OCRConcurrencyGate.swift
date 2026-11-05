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
    func withPermit<T>(cancellation: ConversionCancellationToken? = ConversionExecution.current?.cancellation, _ body: () throws -> T) throws -> T {
        condition.lock()
        do {
            while occupied {
                try cancellation?.checkCancellation()
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            try cancellation?.checkCancellation()
            occupied = true
            condition.unlock()
        } catch { condition.unlock(); throw error }
        defer { release() }
        try cancellation?.checkCancellation()
        return try body()
    }
}
