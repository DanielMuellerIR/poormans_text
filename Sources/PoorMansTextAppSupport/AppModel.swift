import AppKit
import Foundation
import PoorMansTextCore
import UniformTypeIdentifiers

/// Ergebnis einer einzelnen Eingabe innerhalb eines Mehrfachlaufs.
public struct BatchItem: Sendable, Identifiable {
    public enum Outcome: Sendable {
        case succeeded(ConversionResult)
        case failed(String)
    }

    public let input: URL
    public let outcome: Outcome

    public var id: String { input.path }

    public var result: ConversionResult? {
        if case .succeeded(let result) = outcome {
            return result
        }
        return nil
    }

    public init(input: URL, outcome: Outcome) {
        self.input = input
        self.outcome = outcome
    }
}

/// Zwischenstand eines Mehrfachlaufs: was fertig ist, was gerade läuft und
/// wie viele Eingaben es insgesamt sind. `total` ist erst nach dem Durchsuchen
/// der Ordner bekannt; solange steht dort die Zahl der abgelegten Pfade.
public struct BatchProgress: Sendable {
    public let finished: [BatchItem]
    public let current: URL
    public let total: Int

    public init(finished: [BatchItem], current: URL, total: Int) {
        self.finished = finished
        self.current = current
        self.total = total
    }
}

@MainActor
public final class AppModel: ObservableObject {
    public enum State {
        case idle
        case converting(URL)
        case succeeded(ConversionResult)
        case failed(input: URL?, message: String)
        case convertingBatch(BatchProgress)
        case batchFinished([BatchItem])
        /// Rich Text aus dem Dienst wurde umgewandelt und liegt als Markdown in
        /// der Zwischenablage.
        case copiedToClipboard(ClipboardOutcome)
    }

    @Published public private(set) var state: State = .idle
    @Published public var isDropTargeted = false
    /// Gilt nur für Bildimporte; andere Formate ignorieren diese Option.
    @Published public var imageTextRecognition: ImageTextRecognition = .enabled
    /// Wahr, solange die App Pandoc über Homebrew nachinstalliert.
    @Published public private(set) var isInstallingPandoc = false

    public var isConverting: Bool {
        switch state {
        case .converting, .convertingBatch:
            return true
        case .idle, .succeeded, .failed, .batchFinished, .copiedToClipboard:
            return false
        }
    }

    /// Nimmt die App gerade eine neue Datei an? Während einer laufenden
    /// Umwandlung oder Pandoc-Installation bleibt nur ein Auftrag aktiv.
    public var acceptsNewDocuments: Bool {
        !isConverting && !isInstallingPandoc && pendingDrops == 0
    }

    /// Angenommene Drops, deren Datei-URLs noch geladen werden. Solange einer
    /// aussteht, ist die App belegt: Vorher konnte ein zweiter Drop, ein
    /// Finder-Dienst oder ein Öffnen in diesem Fenster ebenfalls angenommen
    /// werden, und `convert(_:)` verwarf den späteren Auftrag stumm
    /// (Review-Fund 2026-09-03).
    private var pendingDrops = 0

    public init() {}

    /// Wandelt eine einzelne Datei oder ein Paket um. Ein durchsuchbarer Ordner
    /// läuft über den Mehrfachweg, damit beide Einstiege gleich reagieren.
    public func convert(_ inputURL: URL) {
        guard acceptsNewDocuments else {
            return
        }
        if InputEnumerator().isSearchableDirectory(inputURL) {
            convert([inputURL])
            return
        }

        state = .converting(inputURL)
        let request = ConversionRequest(
            inputURL: inputURL,
            options: ConversionOptions(imageTextRecognition: imageTextRecognition)
        )

        // Die Dateikonvertierung läuft außerhalb des Main Actors, damit das Fenster
        // während textutil und Pandoc weiterhin reagiert.
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DocumentConverter().convert(request)
                }.value
                state = .succeeded(result)
            } catch {
                state = .failed(input: inputURL, message: error.localizedDescription)
            }
        }
    }

    /// Wandelt mehrere Pfade nacheinander um; Ordner werden dabei nach denselben
    /// Regeln wie in der CLI durchsucht. Genau eine Datei nimmt weiterhin den
    /// Einzelweg mit seiner gewohnten Ergebnisansicht.
    public func convert(_ inputURLs: [URL]) {
        guard acceptsNewDocuments, let first = inputURLs.first else {
            return
        }
        let enumerator = InputEnumerator()
        if inputURLs.count == 1, !enumerator.isSearchableDirectory(first) {
            convert(first)
            return
        }

        state = .convertingBatch(BatchProgress(finished: [], current: first, total: inputURLs.count))
        let options = ConversionOptions(imageTextRecognition: imageTextRecognition)

        Task {
            let inputs: [EnumeratedInput]
            do {
                inputs = try await Task.detached(priority: .userInitiated) {
                    try enumerator.enumerate(inputURLs)
                }.value
            } catch {
                state = .failed(input: first, message: error.localizedDescription)
                return
            }

            var finished = [BatchItem]()
            for input in inputs {
                state = .convertingBatch(
                    BatchProgress(finished: finished, current: input.url, total: inputs.count)
                )
                // Jedes Ergebnis landet neben seiner Quelle; ein gemeinsamer
                // Zielordner ist Sache der CLI.
                let request = ConversionRequest(inputURL: input.url, options: options)
                let outcome: BatchItem.Outcome
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try DocumentConverter().convert(request)
                    }.value
                    outcome = .succeeded(result)
                } catch {
                    outcome = .failed(error.localizedDescription)
                }
                finished.append(BatchItem(input: input.url, outcome: outcome))
            }
            state = .batchFinished(finished)
        }
    }

    public func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsNewDocuments else {
            return false
        }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else {
            return false
        }

        // Alle abgelegten Einträge einsammeln, erst dann einmal umwandeln. Die
        // Reihenfolge bleibt die des Drops, weil jeder Eintrag nacheinander
        // abgewartet wird. Die Reservierung gilt ab jetzt, noch vor dem ersten
        // `await`, und endet unmittelbar vor `convert`.
        pendingDrops += 1
        Task { @MainActor in
            var urls = [URL]()
            for provider in fileProviders {
                if let url = await Self.loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            pendingDrops -= 1
            convert(urls)
        }
        return true
    }

    /// Finder liefert Pakete als explizite Datei-URL. Diese Darstellung ist
    /// auf macOS verlässlicher als die allgemeine SwiftUI-URL-Übertragung.
    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).map { $0 as URL })
            }
        }
    }

    /// Der Einstieg der App: Öffnen-Dialog anzeigen und die Auswahl umwandeln.
    public func chooseDocument() {
        chooseDocument(selectDocuments: { AppModel.presentOpenPanel() })
    }

    /// Dieselbe Auswahl mit austauschbarem Dialog, damit Tests die Sperre prüfen
    /// können, ohne ein echtes Fenster zu öffnen.
    public func chooseDocument(selectDocuments: () -> [URL]) {
        guard acceptsNewDocuments else {
            return
        }
        let urls = selectDocuments()
        guard !urls.isEmpty else {
            return
        }
        convert(urls)
    }

    /// Der echte Öffnen-Dialog von macOS. Mehrfachauswahl und Ordner sind
    /// erlaubt; ein Ordner wird wie beim Drop rekursiv durchsucht.
    private static func presentOpenPanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose Documents, Spreadsheets, PDFs, Images, or a Folder"
        panel.prompt = "Convert"
        let extensions = DocumentConverter().supportedFormatDescriptors
            .flatMap(\.fileExtensions)
        panel.allowedContentTypes = Array(Set(extensions)).sorted().compactMap {
            UTType(filenameExtension: $0)
        } + [.folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else {
            return []
        }
        return panel.urls
    }

    /// Installiert Pandoc über Homebrew und sperrt für die Dauer des Laufs alle
    /// Einstiege: Drop-Zone, „Choose Document…" und per `onOpenURL` geöffnete
    /// Dateien. So überlagert kein zweiter Auftrag die laufende Installation.
    ///
    /// Die eigentliche Installation ist ein Parameter, damit Tests die Sperre
    /// ohne Homebrew nachstellen können.
    ///
    /// Der Rückgabewert sagt, ob dieser Aufruf die Installation wirklich
    /// durchgeführt hat. Ein zweiter, paralleler Aufruf läuft in die Sperre und
    /// meldet `false`: Er darf keinen Erfolg anzeigen, während der erste
    /// Homebrew-Lauf noch läuft oder später scheitert.
    @discardableResult
    public func installPandoc(
        brewExecutable: URL,
        using install: @escaping @Sendable (URL) async throws -> Void = {
            try PandocInstaller.installPandoc(brewExecutable: $0)
        }
    ) async throws -> Bool {
        guard !isInstallingPandoc else {
            return false
        }
        isInstallingPandoc = true
        defer { isInstallingPandoc = false }

        // Wie die Dateikonvertierung läuft der Homebrew-Aufruf außerhalb des
        // Main Actors; `brew install` kann mehrere Minuten dauern.
        try await Task.detached(priority: .userInitiated) {
            try await install(brewExecutable)
        }.value
        return true
    }

    /// Zeigt das Ergebnis im Finder: die Markdown-Datei eines Einzellaufs oder
    /// alle gelungenen Markdown-Dateien eines Mehrfachlaufs.
    public func revealResult() {
        switch state {
        case .succeeded(let result):
            NSWorkspace.shared.activateFileViewerSelecting([result.markdownFile])
        case .batchFinished(let items):
            let files = items.compactMap { $0.result?.markdownFile }
            guard !files.isEmpty else {
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting(files)
        case .idle, .converting, .failed, .convertingBatch, .copiedToClipboard:
            return
        }
    }

    /// Wandelt markierten Rich Text um (Dienst „Convert Text to Markdown“) und
    /// legt das Markdown als Text auf `outputPasteboard`. Die Zwischenablage
    /// wird erst nach gelungener Umwandlung angefasst.
    public func convertRichText(_ source: RichTextClipboard.Source, to outputPasteboard: NSPasteboard) {
        guard acceptsNewDocuments else {
            return
        }
        state = .converting(URL(fileURLWithPath: source.fileName))
        let options = ConversionOptions(imageTextRecognition: imageTextRecognition)

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try RichTextClipboard.convert(source, options: options)
                }.value
                // `setString` meldet `false`, wenn inzwischen ein anderer
                // Prozess die Zwischenablage übernommen hat; dann wäre
                // „copied" eine Falschmeldung.
                outputPasteboard.clearContents()
                guard outputPasteboard.setString(outcome.markdown, forType: .string) else {
                    state = .failed(input: nil, message: "The Markdown could not be placed on the clipboard.")
                    return
                }
                state = .copiedToClipboard(outcome)
            } catch {
                state = .failed(input: nil, message: error.localizedDescription)
            }
        }
    }

    public func reset() {
        guard !isConverting else {
            return
        }
        state = .idle
    }
}
