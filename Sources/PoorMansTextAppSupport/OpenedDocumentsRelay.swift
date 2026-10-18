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
public final class OpenedDocumentsRelay: NSObject, NSApplicationDelegate, NSUserInterfaceValidations {
    public var terminationHandler: (() -> Void)?
    private var pasteHandler: (() -> Void)?
    private var canPaste: (() -> Bool)?
    private var menuObservers: [NSObjectProtocol] = []
    private var installingPasteTarget = false

    public func applicationWillTerminate(_ notification: Notification) {
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers = []
        terminationHandler?()
    }

    /// SwiftUI reserviert ⌘V für seinen Standardeintrag, leitet ihn aber nicht
    /// an den adaptierten App-Delegate weiter. Nur dessen Ziel wird gebunden;
    /// Titel, Kürzel und die übrigen nativen Bearbeitungsbefehle bleiben erhalten.
    public func configurePaste(handler: @escaping () -> Void, canPaste: @escaping () -> Bool) {
        pasteHandler = handler; self.canPaste = canPaste
        installPasteTarget()
        if menuObservers.isEmpty {
            for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
                menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.installPasteTarget() }
                })
            }
        }
        DispatchQueue.main.async { [weak self] in self?.installPasteTarget() }
    }

    private func installPasteTarget() {
        guard !installingPasteTarget, let menu = NSApp?.mainMenu else { return }
        installingPasteTarget = true
        defer { installingPasteTarget = false }
        func isCommand(_ item: NSMenuItem, _ key: String) -> Bool {
            item.keyEquivalent.lowercased() == key &&
                item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command
        }
        // Das Bearbeiten-Menü unabhängig von seiner Sprache erkennen; keine
        // gleich belegten Einträge aus fremden Systemdiensten verändern.
        for topItem in menu.items {
            guard let submenu = topItem.submenu,
                  submenu.items.contains(where: { isCommand($0, "x") }),
                  submenu.items.contains(where: { isCommand($0, "c") }) else { continue }
            for item in submenu.items {
                guard isCommand(item, "v") else { continue }
                if item.target !== self || item.action != #selector(pasteFromMenu(_:)) {
                    item.target = self
                    item.action = #selector(pasteFromMenu(_:))
                }
                // SwiftUI aktualisiert auch die Aktivierung anhand des normalen
                // Paste-Befehls. Unser expliziter Import muss eine leere Ablage
                // erreichen können, um den passenden Hinweis anzuzeigen.
                let enabled = validateUserInterfaceItem(item)
                if item.isEnabled != enabled { item.isEnabled = enabled }
            }
        }
    }

    @objc private func pasteFromMenu(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            editor.paste(sender)
        } else if canPaste?() == true {
            pasteHandler?()
        }
    }

    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(pasteFromMenu(_:)) else { return true }
        return (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true || canPaste?() == true
    }

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
