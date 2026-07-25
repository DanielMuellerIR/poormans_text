import Foundation

/// Vom Konvertierungskern eindeutig erkanntes Quelldokumentformat.
///
/// Der offene String-Wert erlaubt neuen Adaptern ein eigenes Format, ohne diese
/// zentrale Foundation-Grenze um einen Enum-Fall erweitern zu müssen.
public struct InputFormat: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "An input format identifier must not be empty")
        self.rawValue = rawValue
    }

    public static let rtf = InputFormat(rawValue: "rtf")
    public static let rtfd = InputFormat(rawValue: "rtfd")
    public static let docx = InputFormat(rawValue: "docx")
    public static let odt = InputFormat(rawValue: "odt")
    public static let doc = InputFormat(rawValue: "doc")

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard !rawValue.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "An input format identifier must not be empty"
            )
        }
        self.rawValue = rawValue
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
