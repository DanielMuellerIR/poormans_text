import AppKit
import Foundation

/// Empfänger der beiden Systemdienste aus `App/Info.plist`. macOS ruft die
/// Methoden auf dem Main Thread mit dem Pasteboard des aufrufenden Programms
/// auf; die Selektoren müssen den `NSMessage`-Einträgen entsprechen.
///
/// Der Dienst für Dateien übergibt die Auswahl an dasselbe Modell wie Drop und
/// Öffnen-Dialog, holt die App nach vorn und zeigt dort den Fortschritt. Der
/// Dienst für Rich Text legt das Markdown in die allgemeine Zwischenablage.
@MainActor
public final class ServicesProvider: NSObject {
    private let model: AppModel
    private let outputPasteboard: NSPasteboard

    public init(model: AppModel, outputPasteboard: NSPasteboard = .general) {
        self.model = model
        self.outputPasteboard = outputPasteboard
    }

    /// Selektor `convertFilesToMarkdown:userData:error:`.
    @objc public func convertFilesToMarkdown(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            error.pointee = "The service received no files."
            return
        }
        guard model.acceptsNewDocuments else {
            error.pointee = "Poor Man's Text is busy with another conversion."
            return
        }
        NSApp?.activate(ignoringOtherApps: true)
        model.convert(urls)
    }

    /// Selektor `convertRichTextToMarkdown:userData:error:`.
    @objc public func convertRichTextToMarkdown(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let source = RichTextClipboard.Source(pasteboard: pasteboard) else {
            error.pointee = RichTextClipboard.ClipboardError.noRichText.localizedDescription as NSString
            return
        }
        guard model.acceptsNewDocuments else {
            error.pointee = "Poor Man's Text is busy with another conversion."
            return
        }
        NSApp?.activate(ignoringOtherApps: true)
        model.convertRichText(source, to: outputPasteboard)
    }
}
