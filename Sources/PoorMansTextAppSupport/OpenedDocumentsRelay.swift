import AppKit
import Foundation

/// Nimmt Dateien entgegen, die macOS der App zum Öffnen übergibt — per
/// Doppelklick, Ablegen auf dem Dock-Symbol oder `open -a`. Anders als
/// SwiftUIs `onOpenURL`, das jede Datei einzeln meldet, kommen hier alle
/// gleichzeitig geöffneten Dateien als eine Liste an, sodass daraus ein
/// Mehrfachlauf wird statt einer Datei und vielen abgewiesenen.
///
/// Beim Start kann macOS die Liste liefern, bevor das Fenster steht. Dann
/// wartet sie hier, bis die Oberfläche ihren Empfänger eingetragen hat.
@MainActor
public final class OpenedDocumentsRelay: NSObject, NSApplicationDelegate {
    public var handler: (([URL]) -> Void)? {
        didSet {
            guard let handler, !pending.isEmpty else {
                return
            }
            let urls = pending
            pending = []
            handler(urls)
        }
    }
    private var pending = [URL]()

    public func application(_ application: NSApplication, open urls: [URL]) {
        if let handler {
            handler(urls)
        } else {
            pending.append(contentsOf: urls)
        }
    }
}
