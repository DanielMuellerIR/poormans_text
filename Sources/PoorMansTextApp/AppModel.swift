import AppKit
import Foundation
import PoorMansTextCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum State {
        case idle
        case converting(URL)
        case succeeded(ConversionResult)
        case failed(input: URL?, message: String)
    }

    @Published private(set) var state: State = .idle
    @Published var isDropTargeted = false

    var isConverting: Bool {
        if case .converting = state {
            return true
        }
        return false
    }

    func convert(_ inputURL: URL) {
        guard !isConverting else {
            return
        }
        guard inputURL.pathExtension.lowercased() == "rtfd" else {
            state = .failed(
                input: inputURL,
                message: "Please choose a macOS Rich Text with Attachments (.rtfd) document."
            )
            return
        }

        state = .converting(inputURL)

        // Die Dateikonvertierung läuft außerhalb des Main Actors, damit das Fenster
        // während textutil und Pandoc weiterhin reagiert.
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try RTFDConverter().convert(inputURL: inputURL)
                }.value
                state = .succeeded(result)
            } catch {
                state = .failed(input: inputURL, message: error.localizedDescription)
            }
        }
    }

    func chooseDocument() {
        let panel = NSOpenPanel()
        panel.title = "Choose an RTFD Document"
        panel.prompt = "Convert"
        panel.allowedContentTypes = [.rtfd]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        convert(url)
    }

    func revealResult() {
        guard case .succeeded(let result) = state else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([result.markdownFile])
    }

    func reset() {
        guard !isConverting else {
            return
        }
        state = .idle
    }
}
