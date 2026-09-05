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

/// Legt fest, ob Bildimporte zusätzlich lokal erkannten Text ausgeben.
public enum ImageTextRecognition: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
}

public enum PDFTextRecognition: String, Codable, Equatable, Sendable {
    case automatic = "auto"
    case always
    case disabled = "off"
}

public enum PDFLayout: String, Codable, Equatable, Sendable {
    case automatic = "auto"
    case legacy
}

/// Wie das Ergebnis auf der Platte liegt.
public enum OutputLayout: String, Codable, Equatable, Sendable {
    /// `Name-markdown/Name.md` plus `images/`, das bisherige Format.
    case markdownFolder
    /// `Name.textbundle/text.md` plus `assets/` und `info.json`, wie Bear,
    /// iA Writer und Ulysses es öffnen.
    case textbundle
}

public struct ConversionOptions: Equatable, Sendable {
    public var pandocExecutable: URL?
    public var spreadsheetRendering: SpreadsheetRendering
    public var imageTextRecognition: ImageTextRecognition
    /// YAML-Kopf mit Titel, Autor und Daten aus dem Quelldokument voranstellen.
    public var frontmatter: Bool
    public var outputLayout: OutputLayout
    public var pdfTextRecognition: PDFTextRecognition
    public var ocrLanguages: [String]
    public var pdfLayout: PDFLayout
    public var pdfRemoveHeadersFooters: Bool
    public var pdfDehyphenate: Bool

    public init(
        pandocExecutable: URL? = nil,
        spreadsheetRendering: SpreadsheetRendering = .markdownTable,
        imageTextRecognition: ImageTextRecognition = .enabled,
        frontmatter: Bool = false,
        outputLayout: OutputLayout = .markdownFolder,
        pdfTextRecognition: PDFTextRecognition = .automatic,
        ocrLanguages: [String] = [],
        pdfLayout: PDFLayout = .automatic,
        pdfRemoveHeadersFooters: Bool = false,
        pdfDehyphenate: Bool = false
    ) {
        self.pandocExecutable = pandocExecutable
        self.spreadsheetRendering = spreadsheetRendering
        self.imageTextRecognition = imageTextRecognition
        self.frontmatter = frontmatter
        self.outputLayout = outputLayout
        self.pdfTextRecognition = pdfTextRecognition
        self.ocrLanguages = ocrLanguages
        self.pdfLayout = pdfLayout
        self.pdfRemoveHeadersFooters = pdfRemoveHeadersFooters
        self.pdfDehyphenate = pdfDehyphenate
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

    public enum Unit: String, Equatable, Sendable { case file, page, sheet, frame }
    public let phase: Phase
    public let format: InputFormat?
    public let unit: Unit?
    public let completed: Int?
    public let total: Int?

    public init(phase: Phase, format: InputFormat? = nil, unit: Unit? = nil,
                completed: Int? = nil, total: Int? = nil) {
        self.phase = phase
        self.format = format
        self.unit = unit
        self.completed = completed
        self.total = total
    }
}

public typealias ConversionProgressHandler = @Sendable (ConversionProgress) -> Void
