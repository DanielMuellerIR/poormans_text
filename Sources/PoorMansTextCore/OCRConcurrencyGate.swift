import Foundation

/// Vision arbeitet pro Prozess an genau einem Bild. Wartende Dokumente prüfen
/// ihren Abbruch alle 50 ms; normale Dokumentarbeit braucht diesen Slot nicht.
final class OCRConcurrencyGate: @unchecked Sendable {
    static let shared = OCRConcurrencyGate()
    private let condition = NSCondition()
    private var occupied = false
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
        defer {
            condition.lock(); occupied = false; condition.broadcast(); condition.unlock()
        }
        try cancellation?.checkCancellation()
        return try body()
    }
}
