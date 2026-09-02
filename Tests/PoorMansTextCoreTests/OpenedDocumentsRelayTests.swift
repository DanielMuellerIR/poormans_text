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
}
