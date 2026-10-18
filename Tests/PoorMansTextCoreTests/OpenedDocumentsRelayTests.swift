import AppKit
import Foundation
import XCTest
@testable import PoorMansTextAppSupport

/// macOS kann die zu öffnenden Dateien liefern, bevor das Fenster seinen
/// Empfänger eingetragen hat. Nichts davon darf verloren gehen, und alles,
/// was zusammen geöffnet wurde, muss als eine Liste ankommen.
final class OpenedDocumentsRelayTests: XCTestCase {
    @MainActor
    func testURLsOpenedBeforeAHandlerExistsAreDeliveredOnceItIsSet() {
        let relay = OpenedDocumentsRelay()
        let a = URL(fileURLWithPath: "/tmp/a.docx")
        let b = URL(fileURLWithPath: "/tmp/b.pdf")
        relay.application(NSApplication.shared, open: [a])
        relay.application(NSApplication.shared, open: [b])

        var received = [[URL]]()
        relay.handler = { received.append($0) }

        XCTAssertEqual(received, [[a, b]])

        // Danach geht jede Liste sofort und unverändert durch.
        let c = URL(fileURLWithPath: "/tmp/c.png")
        relay.application(NSApplication.shared, open: [c, a])
        XCTAssertEqual(received, [[a, b], [c, a]])
    }

    @MainActor
    func testSettingAHandlerWithoutPendingURLsDeliversNothing() {
        let relay = OpenedDocumentsRelay()
        var calls = 0
        relay.handler = { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
    }
    @MainActor
    func testPasteCommandSurvivesMenuRevalidationWithoutReadingClipboard() {
        let app = NSApplication.shared
        let original = app.mainMenu
        let relay = OpenedDocumentsRelay()
        defer {
            relay.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            app.mainMenu = original
        }
        let menu = NSMenu()
        let edit = NSMenu()
        edit.autoenablesItems = false
        let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(cut); edit.addItem(copy); edit.addItem(paste)
        let top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        top.submenu = edit; menu.addItem(top); app.mainMenu = menu
        var reads = 0
        var accepts = true
        relay.configurePaste(handler: { reads += 1 }, canPaste: { accepts })
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(paste.isEnabled)
        paste.isEnabled = false
        XCTAssertTrue(paste.isEnabled, "An empty clipboard must still reach the explicit import command")
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(cut.action, #selector(NSText.cut(_:)))
        XCTAssertEqual(copy.action, #selector(NSText.copy(_:)))
        edit.performActionForItem(at: 2)
        XCTAssertEqual(reads, 1)
        accepts = false
        relay.configurePaste(handler: { reads += 1 }, canPaste: { accepts })
        XCTAssertFalse(paste.isEnabled)
        XCTAssertEqual(reads, 1)
    }

}
