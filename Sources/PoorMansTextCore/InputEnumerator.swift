import Foundation
#if os(Linux)
import Glibc
#endif

/// Eine einzelne Eingabe, die aus einer Pfadliste hervorgegangen ist.
///
/// `relativeDirectory` ist der Ordnerpfad relativ zu dem Ordner, aus dem die
/// Eingabe beim Durchsuchen stammt. Ein direkt benannter Pfad hat einen leeren
/// Wert. Ein Aufrufer, der alle Ergebnisse in einen gemeinsamen Zielordner
/// legt, spiegelt damit die Ordnerstruktur und vermeidet Namenskollisionen
/// zwischen `a/Bericht.docx` und `b/Bericht.docx` INNERHALB eines
/// durchsuchten Ordners. Werden `a` und `b` dagegen als zwei getrennte
/// Argumente genannt, ist der Wert für beide leer: Zwei gleichnamige Dokumente
/// zielen dann auf denselben Ordner, und die Reservierung im `BatchConverter`
/// weist das zweite mit „Ausgabe existiert bereits" ab
/// (Review-Fund 2026-09-10).
public struct EnumeratedInput: Equatable, Sendable {
    public let url: URL
    public let relativeDirectory: [String]

    public init(url: URL, relativeDirectory: [String] = []) {
        self.url = url
        self.relativeDirectory = relativeDirectory
    }
}

/// Fehler beim Auflösen einer Pfadliste zu einzelnen Eingaben.
public enum InputEnumerationError: LocalizedError, Equatable, Sendable {
    case inputDoesNotExist(URL)
    case noSupportedDocuments(URL)
    /// Der genannte Ordner ist selbst das Ergebnis einer früheren Umwandlung.
    case earlierResult(URL)
    case fileSystemFailure(URL, String)

    public var errorDescription: String? {
        switch self {
        case .inputDoesNotExist(let url):
            return "Input does not exist: \(url.path)"
        case .noSupportedDocuments(let url):
            return "The folder contains no supported documents: \(url.path)"
        case .earlierResult(let url):
            return "The folder is the result of an earlier conversion: \(url.path)"
        case .fileSystemFailure(let url, let message):
            return "Could not read the folder \(url.path): \(message)"
        }
    }
}

/// Löst eine Liste aus Dateien, Paketen und Ordnern zu einzelnen Eingaben auf.
///
/// Die Regeln, damit CLI und App dasselbe Ergebnis liefern:
///
/// - Ein regulärer Pfad und ein Ordnerpaket wie `.rtfd` zählen als genau eine
///   Eingabe und werden ungeprüft übernommen. Ob der Inhalt wirklich passt,
///   entscheidet die inhaltsbasierte Erkennung beim Umwandeln; so bleibt der
///   ehrliche Fehler für eine falsch benannte Datei erhalten.
/// - Ein sonstiger Ordner wird rekursiv durchsucht. Aufgenommen wird nur, was
///   nach der Dateiendung zu einem bekannten Format gehört. Pakete werden
///   aufgenommen, aber nicht betreten.
/// - Versteckte Einträge, symbolische Links und frühere Ergebnisordner
///   (`Name-markdown`, `Name.textbundle`) werden beim Durchsuchen übergangen. Ohne die letzte Regel
///   würde ein zweiter Lauf die Bilder unter `images/` des ersten Laufs erneut
///   umwandeln.
/// - Die Reihenfolge ist die Reihenfolge der Argumente; innerhalb eines Ordners
///   sortiert der Finder-Vergleich. Doppelte Pfade bleiben nur einmal erhalten.
public struct InputEnumerator: Sendable {
    /// Namensendung der Ergebnisordner, die `DocumentConverter.defaultOutputDirectory`
    /// erzeugt. Die Aufzählung übergeht solche Ordner.
    public static let outputDirectorySuffix = "-markdown"
    /// Endung der Textbundle-Ergebnisse; ebenfalls übergangen.
    public static let textbundleExtension = "textbundle"

    private let fileExtensions: Set<String>
    private let packageExtensions: Set<String>

    public init(descriptors: [SupportedFormat]) {
        var recognizedExtensions = Set(descriptors.flatMap { $0.fileExtensions.map { $0.lowercased() } })
        #if os(Linux)
        // Fehlende optionale Decoder gehören als Dokumentfehler in den Batch,
        // statt bekannte HEIC-Quellen bei der Ordnersuche still zu übergehen.
        if descriptors.contains(where: { $0.format == .image }) { recognizedExtensions.insert("heic") }
        #endif
        fileExtensions = recognizedExtensions
        packageExtensions = Set(
            descriptors
                .filter { $0.containerKinds.contains(.package) }
                .flatMap { $0.fileExtensions.map { $0.lowercased() } }
        )
    }

    public init(converter: DocumentConverter = DocumentConverter()) {
        self.init(descriptors: converter.supportedFormatDescriptors)
    }

    /// Trägt der Ordner den Namen, den eine frühere Umwandlung erzeugt hat?
    /// Dieselbe Regel gilt beim Durchsuchen und für einen direkt genannten
    /// Ordner — sonst wandelt ein zweiter Lauf die Bilder des ersten erneut um
    /// und legt das Ergebnis IN den alten Ergebnisordner (Review-Fund 2026-09-10).
    static func isEarlierResult(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(outputDirectorySuffix)
            || url.pathExtension.lowercased() == textbundleExtension
    }

    /// Ist der Pfad ein Ordner, der durchsucht werden muss? `false` für Dateien
    /// und für Ordnerpakete, die als ein Dokument gelten. Ein fehlender Pfad
    /// gilt hier ebenfalls als `false`; der Fehler kommt später aus `enumerate`.
    public func isSearchableDirectory(_ url: URL) -> Bool {
        #if os(Linux)
        guard (try? LinuxPathValidation.validate(url)) != nil else { return false }
        #endif
        let url = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return !isPackage(url)
    }

    public func enumerate(_ roots: [URL], cancellation: ConversionCancellationToken? = nil) throws -> [EnumeratedInput] {
        var seen = Set<String>()
        var result = [EnumeratedInput]()

        func append(_ input: EnumeratedInput) {
            guard seen.insert(FileSystemPath.key(input.url.standardizedFileURL.path)).inserted else {
                return
            }
            result.append(input)
        }

        // Ein fehlender Pfad oder ein leerer Ordner bricht die
        // ganze Aufzählung ab, bevor ein Dokument umgewandelt wird — das ist
        // ein Argumentfehler des Aufrufers, kein Dokumentfehler. Die
        // Fortsetzung „ein Fehler hält die übrigen nicht auf" gilt für die
        // Umwandlung der gefundenen Dokumente; CLI (Exit 66) und App zeigen
        // den Argumentfehler sofort (Tests in CLIBatchTests und
        // AppModelBatchTests, README-Absatz zum Mehrfachlauf).
        for requestedRoot in roots {
            #if os(Linux)
            try LinuxPathValidation.validate(requestedRoot)
            #endif
            let root = requestedRoot.standardizedFileURL
            try cancellation?.checkCancellation()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                throw InputEnumerationError.inputDoesNotExist(root)
            }
            guard isDirectory.boolValue, !isPackage(root) else {
                append(EnumeratedInput(url: root))
                continue
            }

            guard !Self.isEarlierResult(root) else {
                throw InputEnumerationError.earlierResult(root)
            }
            let found = try search(root, cancellation: cancellation)
            guard !found.isEmpty else {
                throw InputEnumerationError.noSupportedDocuments(root)
            }
            for input in found {
                append(input)
            }
        }

        return result
    }

    private func isPackage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return packageExtensions.contains(ext)
    }

    private func isSupportedByExtension(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    private func search(_ root: URL, cancellation: ConversionCancellationToken?) throws -> [EnumeratedInput] {
        #if os(Linux)
        return try searchLinux(root, cancellation: cancellation)
        #else
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var failure: (URL, Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                failure = (url, error)
                return false
            }
        ) else {
            throw InputEnumerationError.fileSystemFailure(root, "enumeration could not start")
        }

        var found = [EnumeratedInput]()
        let rootComponents = root.pathComponents
        for case let entry as URL in enumerator {
            try cancellation?.checkCancellation()
            let values = try? entry.resourceValues(forKeys: Set(keys))
            // Symbolische Links werden nicht verfolgt: Ein Link auf einen
            // Elternordner wäre eine Endlosschleife, ein Link nach außen
            // zöge fremde Dokumente in den Lauf.
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values?.isDirectory == true {
                if isPackage(entry) {
                    enumerator.skipDescendants()
                    found.append(makeInput(entry, rootComponents: rootComponents))
                } else if Self.isEarlierResult(entry) {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values?.isRegularFile == true, isSupportedByExtension(entry) {
                found.append(makeInput(entry, rootComponents: rootComponents))
            }
        }

        if let (url, error) = failure {
            throw InputEnumerationError.fileSystemFailure(url, error.localizedDescription)
        }

        // Finder-Reihenfolge, damit „Kapitel 2" vor „Kapitel 10" kommt und der
        // Lauf bei jedem Aufruf gleich sortiert ist.
        return found.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        #endif
    }

    #if os(Linux)
    private func searchLinux(_ root: URL, cancellation: ConversionCancellationToken?) throws -> [EnumeratedInput] {
        var found: [EnumeratedInput] = []
        let rootComponents = root.pathComponents
        func failure(_ url: URL, _ message: String) -> InputEnumerationError {
            .fileSystemFailure(url, message)
        }
        func visit(_ descriptor: Int32, at url: URL, depth: Int = 0) throws {
            guard depth <= 256 else { throw failure(url, "folder nesting exceeds the enumeration limit") }
            let listing = dup(descriptor)
            guard listing >= 0, let directory = fdopendir(listing) else {
                if listing >= 0 { close(listing) }
                throw failure(url, "enumeration could not start")
            }
            defer { closedir(directory) }
            while true {
                try cancellation?.checkCancellation()
                errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw failure(url, "enumeration could not finish") }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                        String(validatingCString: $0)
                    }
                }
                guard let name else { throw failure(url, "an entry name is not valid UTF-8") }
                guard name != ".", name != "..", !name.hasPrefix(".") else { continue }
                var metadata = stat()
                guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw failure(url, "an entry could not be inspected")
                }
                let kind = metadata.st_mode & S_IFMT
                if kind == S_IFLNK { continue }
                let child = url.appendingPathComponent(name, isDirectory: kind == S_IFDIR)
                if kind == S_IFDIR {
                    if isPackage(child) { found.append(makeInput(child, rootComponents: rootComponents)); continue }
                    if Self.isEarlierResult(child) { continue }
                    let nested = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard nested >= 0 else { throw failure(child, "the directory could not be opened safely") }
                    defer { close(nested) }
                    try visit(nested, at: child, depth: depth + 1)
                } else if kind == S_IFREG, isSupportedByExtension(child) {
                    found.append(makeInput(child, rootComponents: rootComponents))
                }
            }
        }
        let descriptor = root.withUnsafeFileSystemRepresentation { path in
            path.map { Glibc.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw failure(root, "the directory could not be opened") }
        defer { close(descriptor) }
        try visit(descriptor, at: root)
        return found.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
    #endif

    private func makeInput(_ url: URL, rootComponents: [String]) -> EnumeratedInput {
        let components = url.standardizedFileURL.pathComponents
        let relative = components.dropFirst(rootComponents.count).dropLast()
        return EnumeratedInput(url: url.standardizedFileURL, relativeDirectory: Array(relative))
    }
}
