import Foundation

/// Ungekürzte Warnungsliste für die kompakte, scrollbare Erfolgsansicht.
public struct WarningPresentation: Equatable, Sendable {
    public let messages: [String]

    public init(warnings: [String]) {
        messages = warnings
    }
}
