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
    @Published public var imageTextRecognition: ImageTextRecognition = .enabled { didSet { savePreferences() } }
    @Published public var spreadsheetRendering: SpreadsheetRendering = .markdownTable { didSet { savePreferences() } }
    @Published public var frontmatter = false { didSet { savePreferences() } }
    @Published public var outputLayout: OutputLayout = .markdownFolder { didSet { savePreferences() } }
    @Published public var destinationFolder: URL? { didSet { savePreferences() } }
    @Published public var selectedInput: String?
    @Published public private(set) var actionMessage: String?
    @Published public private(set) var preview: MarkdownPreview?
    private let defaults: UserDefaults
    private var loadingPreferences = true
    private var destinationOverrides: [String: URL] = [:]
    private var failedEnumerationInputs: [URL] = []
    private var relativeDirectories: [String: [String]] = [:]

    public var conversionOptions: ConversionOptions {
        ConversionOptions(spreadsheetRendering: spreadsheetRendering,
            imageTextRecognition: imageTextRecognition, frontmatter: frontmatter, outputLayout: outputLayout)
    }

    public var selectedResult: ConversionResult? {
        switch state {
        case .succeeded(let result): return result
        case .batchFinished(let items): return items.first { $0.id == selectedInput }?.result
        default: return nil
        }
    }

    public var failedInputs: [URL] {
        switch state {
        case .failed(let input, _): return input.map { [$0] } ?? []
        case .batchFinished(let items): return items.filter { $0.result == nil }.map(\.input)
        default: return []
        }
    }
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        imageTextRecognition = defaults.string(forKey: "imageTextRecognition").flatMap(ImageTextRecognition.init(rawValue:)) ?? .enabled
        spreadsheetRendering = defaults.string(forKey: "spreadsheetRendering").flatMap(SpreadsheetRendering.init(rawValue:)) ?? .markdownTable
        frontmatter = defaults.bool(forKey: "frontmatter")
        outputLayout = defaults.string(forKey: "outputLayout").flatMap(OutputLayout.init(rawValue:)) ?? .markdownFolder
        destinationFolder = defaults.string(forKey: "destinationFolder").map { URL(fileURLWithPath: $0) }
        loadingPreferences = false
    }

    private func savePreferences() {
        guard !loadingPreferences else { return }
        defaults.set(imageTextRecognition.rawValue, forKey: "imageTextRecognition")
        defaults.set(spreadsheetRendering.rawValue, forKey: "spreadsheetRendering")
        defaults.set(frontmatter, forKey: "frontmatter")
        defaults.set(outputLayout.rawValue, forKey: "outputLayout")
        defaults.set(destinationFolder?.path, forKey: "destinationFolder")
    }

    public func request(for input: URL, options: ConversionOptions) -> ConversionRequest {
        let destination = destinationOverrides[input.path] ?? destinationFolder.map {
            let parent = (relativeDirectories[input.path] ?? []).reduce($0) { $0.appendingPathComponent($1, isDirectory: true) }
            return parent.appendingPathComponent(DocumentConverter.outputDirectoryName(for: input, layout: options.outputLayout))
        }
        return ConversionRequest(inputURL: input, destination: destination.map(ConversionDestination.directory) ?? .adjacentToInput, options: options)
    }

    /// Die Elternordner entstehen vor dem Engine-Aufruf. Deshalb schon hier
    /// alle Quelldokumente des Batches schützen, auch ein anderes RTFD-Paket.
    nonisolated private static func prepareParent(for request: ConversionRequest, protecting inputs: [URL]) throws {
        guard case .directory(let output) = request.destination else { return }
        let resolvedOutputPath = output.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for input in inputs {
            let resolvedInput = input.standardizedFileURL.resolvingSymlinksInPath()
            let caseSensitive = (try? resolvedInput.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == true
            let inputPath = resolvedInput.path + "/"
            let liesInside = caseSensitive ? resolvedOutputPath.hasPrefix(inputPath)
                : resolvedOutputPath.lowercased().hasPrefix(inputPath.lowercased())
            guard !liesInside else {
                throw ConversionError.outputInsideInput(output)
            }
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func chooseDestinationFolder() {
        guard acceptsNewDocuments else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { destinationFolder = panel.url }
    }

    /// Der Dialog wählt einen neuen Ergebnisordner; die Engine prüft weiterhin
    /// atomar auf Kollisionen, auch wenn nach dem Dialog jemand das Ziel anlegt.
    public func chooseAlternativeDestination(for input: URL) {
        guard acceptsNewDocuments else { return }
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Choose a new output folder name", comment: "")
        panel.nameFieldStringValue = DocumentConverter.outputDirectoryName(for: input, layout: outputLayout)
        panel.directoryURL = destinationFolder ?? input.deletingLastPathComponent()
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            destinationOverrides[input.path] = outputLayout == .textbundle && url.pathExtension.lowercased() != "textbundle"
                ? url.appendingPathExtension("textbundle") : url
            retryFailed(only: input)
        }
    }

    public func selectResult(_ item: BatchItem) {
        selectedInput = item.id
        preview = nil
        actionMessage = nil
    }

    public func openResult() {
        guard let result = selectedResult else { return }
        if !NSWorkspace.shared.open(result.markdownFile) {
            actionMessage = NSLocalizedString("The Markdown file could not be opened.", comment: "")
        }
    }

    public func loadPreview() {
        guard let result = selectedResult else { return }
        do { preview = try MarkdownPreview.read(result.markdownFile) }
        catch { actionMessage = AppErrorMessage.describe(error) }
    }

    public func copyMarkdown(to pasteboard: NSPasteboard = .general) {
        guard let result = selectedResult else { return }
        do {
            let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                actionMessage = NSLocalizedString("The Markdown could not be placed on the clipboard.", comment: "")
                return
            }
            actionMessage = result.assets.isEmpty
                ? NSLocalizedString("Markdown copied to the clipboard", comment: "")
                : NSLocalizedString("Markdown copied. Image and attachment files were not copied; relative links require the output folder.", comment: "")
        } catch { actionMessage = AppErrorMessage.describe(error) }
    }

    public func retryFailed(only input: URL? = nil) {
        guard acceptsNewDocuments else { return }
        if !failedEnumerationInputs.isEmpty {
            convert(failedEnumerationInputs)
            return
        }
        if case .batchFinished(let items) = state {
            let retry = items.filter { $0.result == nil && (input == nil || $0.input == input) }
            guard let first = retry.first else { return }
            let options = conversionOptions
            let requests = retry.map { request(for: $0.input, options: options) }
            state = .convertingBatch(BatchProgress(finished: items.filter { $0.result != nil }, current: first.input, total: items.count))
            Task {
                var updated = items
                for (item, request) in zip(retry, requests) {
                    let outcome: BatchItem.Outcome
                    do {
                        let result = try await Task.detached(priority: .userInitiated) {
                            try Self.prepareParent(for: request, protecting: items.map(\.input))
                            return try DocumentConverter().convert(request)
                        }.value
                        outcome = .succeeded(result)
                    } catch { outcome = .failed(AppErrorMessage.describe(error)) }
                    if let index = updated.firstIndex(where: { $0.id == item.id }) {
                        updated[index] = BatchItem(input: item.input, outcome: outcome)
                    }
                }
                state = .batchFinished(updated)
            }
        } else if let first = failedInputs.first { convertSingle(first, isRetry: true) }
    }

    /// Wandelt eine einzelne Datei oder ein Paket um. Ein durchsuchbarer Ordner
    /// läuft über den Mehrfachweg, damit beide Einstiege gleich reagieren.
    public func convert(_ inputURL: URL) {
        convertSingle(inputURL, isRetry: false)
    }

    private func convertSingle(_ inputURL: URL, isRetry: Bool) {
        guard acceptsNewDocuments else {
            return
        }
        if InputEnumerator().isSearchableDirectory(inputURL) {
            convert([inputURL])
            return
        }

        if !isRetry {
            failedEnumerationInputs = []
            destinationOverrides = [:]
            relativeDirectories = [:]
        }
        state = .converting(inputURL)
        preview = nil
        actionMessage = nil
        let request = request(for: inputURL, options: conversionOptions)

        // Die Dateikonvertierung läuft außerhalb des Main Actors, damit das Fenster
        // während textutil und Pandoc weiterhin reagiert.
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DocumentConverter().convert(request)
                }.value
                state = .succeeded(result)
            } catch {
                state = .failed(input: inputURL, message: AppErrorMessage.describe(error))
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

        destinationOverrides = [:]
        relativeDirectories = [:]
        failedEnumerationInputs = []
        state = .convertingBatch(BatchProgress(finished: [], current: first, total: inputURLs.count))
        let options = conversionOptions
        let outputRoot = destinationFolder
        let overrides = destinationOverrides
        preview = nil
        actionMessage = nil

        Task {
            let inputs: [EnumeratedInput]
            do {
                inputs = try await Task.detached(priority: .userInitiated) {
                    try enumerator.enumerate(inputURLs)
                }.value
            } catch {
                failedEnumerationInputs = inputURLs
                state = .failed(input: first, message: AppErrorMessage.describe(error))
                return
            }

            relativeDirectories = Dictionary(uniqueKeysWithValues: inputs.map { ($0.url.path, $0.relativeDirectory) })
            var finished = [BatchItem]()
            for input in inputs {
                state = .convertingBatch(
                    BatchProgress(finished: finished, current: input.url, total: inputs.count)
                )
                let parent = outputRoot.map { root in
                    input.relativeDirectory.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
                }
                let destination = overrides[input.url.path] ?? parent.map {
                    $0.appendingPathComponent(DocumentConverter.outputDirectoryName(for: input.url, layout: options.outputLayout))
                }
                let request = ConversionRequest(inputURL: input.url,
                    destination: destination.map(ConversionDestination.directory) ?? .adjacentToInput, options: options)
                let outcome: BatchItem.Outcome
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try Self.prepareParent(for: request, protecting: inputs.map(\.url))
                        return try DocumentConverter().convert(request)
                    }.value
                    outcome = .succeeded(result)
                } catch {
                    outcome = .failed(AppErrorMessage.describe(error))
                }
                finished.append(BatchItem(input: input.url, outcome: outcome))
            }
            selectedInput = finished.first(where: { $0.result != nil })?.id
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
        panel.title = NSLocalizedString("Choose Documents, Spreadsheets, PDFs, Images, or a Folder", comment: "")
        panel.prompt = NSLocalizedString("Convert", comment: "")
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
            let files = items.filter { selectedInput == nil || $0.id == selectedInput }.compactMap { $0.result?.markdownFile }
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
        let options = conversionOptions

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
                state = .failed(input: nil, message: AppErrorMessage.describe(error))
            }
        }
    }

    public func reset() {
        guard !isConverting else {
            return
        }
        preview = nil
        actionMessage = nil
        selectedInput = nil
        destinationOverrides = [:]
        relativeDirectories = [:]
        failedEnumerationInputs = []
        state = .idle
    }
}
