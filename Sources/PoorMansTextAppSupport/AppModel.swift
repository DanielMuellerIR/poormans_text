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

    public var isConverting: Bool {
        if case .converting = state {
            return true
        }
        return false
    }

    public init() {}

    public func convert(_ inputURL: URL) {
        guard !isConverting else {
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

    public func chooseDocument() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Word-Processing Document"
        panel.prompt = "Convert"
        panel.allowedContentTypes = ["rtf", "rtfd", "docx", "odt", "doc"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        convert(url)
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
