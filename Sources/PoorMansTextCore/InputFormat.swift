import Foundation

/// Vom Konvertierungskern eindeutig erkanntes Quelldokumentformat.
public enum InputFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case rtf
    case rtfd
}

/// Ergebnis der Formatprüfung, das eine aufrufende App vor der Konvertierung
/// anzeigen kann, ohne selbst Formatwissen zu duplizieren.
public struct InputInspection: Sendable {
    public let inputURL: URL
    public let format: InputFormat
    public let expectedWarnings: [ConversionWarning]

    public init(
        inputURL: URL,
        format: InputFormat,
        expectedWarnings: [ConversionWarning]
    ) {
        self.inputURL = inputURL
        self.format = format
        self.expectedWarnings = expectedWarnings
    }
}
