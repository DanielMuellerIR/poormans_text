import Foundation

/// Ein Auftrag besitzt einen Token; alle synchron aufgerufenen Adapter teilen
/// ihn. `cancel` darf von jedem Thread kommen, auch während ein Werkzeug läuft.
public final class ConversionCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: ConversionError?
    private let parent: ConversionCancellationToken?

    public init() { parent = nil }
    init(parent: ConversionCancellationToken?) { self.parent = parent }
    public var isCancelled: Bool { lock.withLock { reason != nil } || parent?.isCancelled == true }
    public func cancel() { stop(.cancelled) }
    func stop(_ error: ConversionError) { lock.withLock { if reason == nil { reason = error } } }
    public func checkCancellation() throws {
        try parent?.checkCancellation()
        if let reason = lock.withLock({ reason }) { throw reason }
    }
}

/// Nur innerhalb einer synchronen Konvertierung gebunden. Verschachtelte ODM-
/// Importe erben den Kontext; parallele Aufträge bekommen getrennte Bindungen.
enum ConversionExecution {
    struct Context: Sendable {
        let cancellation: ConversionCancellationToken
        let progress: ConversionProgressHandler?
        let processTimeout: TimeInterval?
        var protectedInputs: [URL] = []
        var plannedSources: [String: URL] = [:]
    }
    @TaskLocal static var current: Context?

    static func check() throws { try current?.cancellation.checkCancellation() }
    static var isCancelled: Bool { current?.cancellation.isCancelled ?? false }
    static func report(_ progress: ConversionProgress) throws {
        try check()
        current?.progress?(progress)
        try check()
    }
    static func report(unit: ConversionProgress.Unit, completed: Int, total: Int) throws {
        try report(ConversionProgress(phase: .converting, unit: unit, completed: completed, total: total))
    }
}
