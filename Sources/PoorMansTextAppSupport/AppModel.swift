import AppKit
import Foundation
import PoorMansTextCore
import UniformTypeIdentifiers

@MainActor
public final class AppModel: ObservableObject {
    public enum State {
        case idle
        case converting(URL)
        case succeeded(ConversionResult)
        case failed(input: URL?, message: String)
    }

    @Published public private(set) var state: State = .idle
    @Published public var isDropTargeted = false
    /// Wahr, solange die App Pandoc über Homebrew nachinstalliert.
    @Published public private(set) var isInstallingPandoc = false

    public var isConverting: Bool {
        if case .converting = state {
            return true
        }
        return false
    }

    /// Nimmt die App gerade eine neue Datei an? Während einer laufenden
    /// Umwandlung oder Pandoc-Installation bleibt nur ein Auftrag aktiv.
    public var acceptsNewDocuments: Bool {
        !isConverting && !isInstallingPandoc
    }

    public init() {}

    public func convert(_ inputURL: URL) {
        guard acceptsNewDocuments else {
            return
        }

        state = .converting(inputURL)
        let request = ConversionRequest(inputURL: inputURL)

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

    public func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsNewDocuments else {
            return false
        }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        // Finder liefert Pakete als explizite Datei-URL. Diese Darstellung ist
        // auf macOS verlässlicher als die allgemeine SwiftUI-URL-Übertragung.
        provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
            guard let nsURL = object as? NSURL else {
                return
            }
            let url = nsURL as URL
            Task { @MainActor in
                self?.convert(url)
            }
        }
        return true
    }

    /// Der Einstieg der App: Öffnen-Dialog anzeigen und die Auswahl umwandeln.
    public func chooseDocument() {
        chooseDocument(selectDocument: { AppModel.presentOpenPanel() })
    }

    /// Dieselbe Auswahl mit austauschbarem Dialog, damit Tests die Sperre prüfen
    /// können, ohne ein echtes Fenster zu öffnen.
    public func chooseDocument(selectDocument: () -> URL?) {
        guard acceptsNewDocuments else {
            return
        }
        guard let url = selectDocument() else {
            return
        }
        convert(url)
    }

    /// Der echte Öffnen-Dialog von macOS.
    private static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Document or Spreadsheet"
        panel.prompt = "Convert"
        let extensions = DocumentConverter().supportedFormatDescriptors
            .flatMap(\.fileExtensions)
        panel.allowedContentTypes = Array(Set(extensions)).sorted().compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
    }

    /// Installiert Pandoc über Homebrew und sperrt für die Dauer des Laufs alle
    /// Einstiege: Drop-Zone, „Choose Document…" und per `onOpenURL` geöffnete
    /// Dateien. So überlagert kein zweiter Auftrag die laufende Installation.
    ///
    /// Die eigentliche Installation ist ein Parameter, damit Tests die Sperre
    /// ohne Homebrew nachstellen können.
    public func installPandoc(
        brewExecutable: URL,
        using install: @escaping @Sendable (URL) async throws -> Void = {
            try PandocInstaller.installPandoc(brewExecutable: $0)
        }
    ) async throws {
        guard !isInstallingPandoc else {
            return
        }
        isInstallingPandoc = true
        defer { isInstallingPandoc = false }

        // Wie die Dateikonvertierung läuft der Homebrew-Aufruf außerhalb des
        // Main Actors; `brew install` kann mehrere Minuten dauern.
        try await Task.detached(priority: .userInitiated) {
            try await install(brewExecutable)
        }.value
    }

    public func revealResult() {
        guard case .succeeded(let result) = state else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([result.markdownFile])
    }

    public func reset() {
        guard !isConverting else {
            return
        }
        state = .idle
    }
}
