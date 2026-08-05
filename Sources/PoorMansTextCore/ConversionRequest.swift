import Foundation

/// Legt fest, wie lange und an welcher Stelle das Ergebnis veröffentlicht wird.
public enum ConversionDestination: Equatable, Sendable {
    /// Dauerhafter Nachbarordner mit dem bisherigen Namen `Eingabe-markdown`.
    case adjacentToInput
    /// Dauerhafter, vom Aufrufer festgelegter Ordner.
    case directory(URL)
    /// Eindeutiger temporärer Ordner, den der Aufrufer nach Gebrauch entfernt.
    case temporary
}

/// Werkzeugoptionen, die App, CLI und spätere Hosts einheitlich übergeben.
public enum SpreadsheetRendering: String, Codable, Equatable, Sendable {
    case markdownTable
    case tabSeparated
}

public struct ConversionOptions: Equatable, Sendable {
    public var pandocExecutable: URL?
    public var spreadsheetRendering: SpreadsheetRendering

    public init(
        pandocExecutable: URL? = nil,
        spreadsheetRendering: SpreadsheetRendering = .markdownTable
    ) {
        self.pandocExecutable = pandocExecutable
        self.spreadsheetRendering = spreadsheetRendering
    }
}

/// Vollständige, GUI-unabhängige Anfrage an den Konvertierungskern.
public struct ConversionRequest: Equatable, Sendable {
    public let inputURL: URL
    public let destination: ConversionDestination
    public let options: ConversionOptions

    public init(
        inputURL: URL,
        destination: ConversionDestination = .adjacentToInput,
        options: ConversionOptions = ConversionOptions()
    ) {
        self.inputURL = inputURL
        self.destination = destination
        self.options = options
    }
}

/// Grobe Phase einer synchronen Konvertierung. Der Callback läuft auf dem
/// Konvertierungs-Thread; UI-Aufrufer wechseln bei Bedarf selbst zum Main Actor.
public struct ConversionProgress: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case detectingInput
        case preparingOutput
        case converting
        case publishing
        case finished
    }

    public let phase: Phase
    public let format: InputFormat?

    public init(phase: Phase, format: InputFormat? = nil) {
        self.phase = phase
        self.format = format
    }
}

public typealias ConversionProgressHandler = @Sendable (ConversionProgress) -> Void
