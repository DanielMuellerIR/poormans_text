import Foundation

/// Wie eine Quelle auf der Platte liegt.
///
/// Ein Host muss das wissen, bevor er eine Auswahl anbietet: `.package` sieht im
/// Finder wie ein Ordner aus (`.rtfd`), ist aber ein Dokument. Ein Editor, der
/// Ordner sonst als Projekt öffnet, braucht genau diese Unterscheidung.
public enum InputContainerKind: String, Codable, Sendable {
    case file
    case package
}

/// Ein Quellformat mit allem, was ein aufrufender Host braucht, um ohne eigenes
/// Formatwissen zu entscheiden, ob er eine Datei zur Umwandlung anbieten darf.
///
/// Die Endungen sind bewusst Teil des veröffentlichten Vertrags. Die eigentliche
/// Erkennung bleibt inhaltsbasiert; ein Host darf die Endung nur als schnellen
/// Vorfilter benutzen und muss den ehrlichen Fehler aus `convert` akzeptieren,
/// wenn der Inhalt doch nicht passt.
public struct SupportedFormat: Sendable, Equatable {
    public let format: InputFormat
    /// Kleingeschriebene Dateiendungen ohne Punkt, Hauptendung zuerst.
    public let fileExtensions: [String]
    public let containerKind: InputContainerKind
    /// Externe Werkzeuge, ohne die dieses Format nicht konvertierbar ist.
    public let requiredTools: [ExternalTool]

    public init(
        format: InputFormat,
        fileExtensions: [String],
        containerKind: InputContainerKind,
        requiredTools: [ExternalTool]
    ) {
        self.format = format
        self.fileExtensions = fileExtensions
        self.containerKind = containerKind
        self.requiredTools = requiredTools
    }
}

/// Ein externes Programm, das ein Adapter zur Laufzeit benötigt.
///
/// Der Kern lädt nichts nach und installiert nichts; fehlt ein Werkzeug, ist das
/// betroffene Format ehrlich nicht verfügbar.
public struct ExternalTool: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "An external tool identifier must not be empty")
        self.rawValue = rawValue
    }

    public static let pandoc = ExternalTool(rawValue: "pandoc")
    public static let textutil = ExternalTool(rawValue: "textutil")
}

/// Ein Format samt aktueller Verfügbarkeit auf DIESEM Rechner.
///
/// `isAvailable == false` heißt nicht „kennt das Format nicht", sondern „das
/// nötige Werkzeug fehlt gerade". Der Grund ist für Nutzertexte gedacht.
public struct FormatAvailability: Sendable, Equatable {
    public let format: SupportedFormat
    public let isAvailable: Bool
    /// Nur gesetzt, wenn `isAvailable == false`.
    public let unavailableReason: String?
    /// Werkzeuge, die für dieses Format fehlen — Teilmenge von `requiredTools`.
    public let missingTools: [ExternalTool]

    public init(
        format: SupportedFormat,
        isAvailable: Bool,
        unavailableReason: String?,
        missingTools: [ExternalTool]
    ) {
        self.format = format
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.missingTools = missingTools
    }
}

/// Prüft, ob ein externes Werkzeug vorhanden ist — ohne es auszuführen.
///
/// Bewusst nur ein Dateisystem-Test: Ein `pandoc --version` je Formatabfrage
/// würde einen Host, der beim Öffnen jeder Datei fragt, spürbar ausbremsen.
/// Nicht `Sendable`: `FileManager` ist es nicht, und der Resolver wird immer
/// synchron dort benutzt, wo er erzeugt wurde.
public struct ExternalToolResolver {
    private let pandocExecutable: URL?
    private let fileManager: FileManager

    public init(pandocExecutable: URL? = nil, fileManager: FileManager = .default) {
        self.pandocExecutable = pandocExecutable
        self.fileManager = fileManager
    }

    public func isAvailable(_ tool: ExternalTool) -> Bool {
        switch tool {
        case .pandoc:
            return (try? PandocTool.resolve(pandocExecutable, fileManager: fileManager)) != nil
        case .textutil:
            return fileManager.isExecutableFile(atPath: LegacyWordAdapter.textutilPath)
        default:
            // Ein neues Werkzeug ohne Prüfweg gilt als NICHT verfügbar. Das ist
            // die sichere Richtung: lieber ein Format zu wenig anbieten als eine
            // Umwandlung anbieten, die verlässlich scheitert.
            return false
        }
    }
}
