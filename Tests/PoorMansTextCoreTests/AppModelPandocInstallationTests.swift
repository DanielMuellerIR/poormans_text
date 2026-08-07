import AppKit
import Foundation
import XCTest
@testable import PoorMansTextAppSupport

/// Während `brew install pandoc` läuft, ist Pandoc noch nicht da. Blieben
/// Drop-Zone, Dateiauswahl und `onOpenURL` in dieser Zeit offen, liefe jede
/// Anfrage sofort in `pandocNotFound` — obwohl das Fenster gerade
/// „Installing Pandoc…" anzeigt.
final class AppModelPandocInstallationTests: XCTestCase {
    @MainActor
    func testEveryEntryPointIsBlockedWhilePandocIsInstalling() async throws {
        let model = AppModel()
        let gate = InstallationGate()
        let document = URL(fileURLWithPath: "/tmp/PoorMansTextNeverConverted.rtf")

        let installation = Task {
            try await model.installPandoc(brewExecutable: Self.brewExecutable) { _ in
                await gate.waitForRelease()
            }
        }
        try await waitUntil("die Installation läuft") { model.isInstallingPandoc }
        XCTAssertFalse(model.acceptsNewDocuments)

        // Einstieg 1: `onOpenURL` reicht die Datei direkt an `convert` weiter.
        model.convert(document)
        XCTAssertFalse(model.isConverting, "Die Umwandlung lief trotz laufender Installation an.")

        // Einstieg 2: die Drop-Zone.
        let provider = NSItemProvider(object: document as NSURL)
        XCTAssertFalse(
            model.acceptDrop([provider]),
            "Die Drop-Zone nahm das Dokument trotz laufender Installation an."
        )

        // Einstieg 3: die Dokumentauswahl. Der Dialog darf gar nicht erscheinen.
        var panelWasPresented = false
        model.chooseDocument {
            panelWasPresented = true
            return document
        }
        XCTAssertFalse(panelWasPresented, "Der Öffnen-Dialog erschien trotz laufender Installation.")
        XCTAssertFalse(model.isConverting)

        await gate.release()
        _ = try await installation.value

        XCTAssertFalse(model.isInstallingPandoc)
        XCTAssertTrue(model.acceptsNewDocuments)
    }

    /// Ein zweiter, paralleler Aufruf läuft in die Sperre. Er darf nicht wie
    /// eine abgeschlossene Installation aussehen — sonst zeigt die App
    /// „Pandoc Installed", während der erste Homebrew-Lauf noch läuft.
    @MainActor
    func testASecondParallelInstallationIsNotReportedAsCompleted() async throws {
        let model = AppModel()
        let gate = InstallationGate()
        let counter = InstallationCounter()

        let installation = Task {
            try await model.installPandoc(brewExecutable: Self.brewExecutable) { _ in
                await counter.increment()
                await gate.waitForRelease()
            }
        }
        try await waitUntil("die Installation läuft") { model.isInstallingPandoc }

        let second = try await model.installPandoc(brewExecutable: Self.brewExecutable) { _ in
            await counter.increment()
        }
        XCTAssertFalse(second, "Der abgewiesene Aufruf meldete eine abgeschlossene Installation.")

        await gate.release()
        let first = try await installation.value

        XCTAssertTrue(first, "Der ausführende Aufruf meldete keine Installation.")
        let runs = await counter.count
        XCTAssertEqual(runs, 1)
    }

    /// Die Sperre muss auch dann fallen, wenn Homebrew scheitert — sonst bliebe
    /// die App nach einer misslungenen Installation dauerhaft blockiert.
    @MainActor
    func testAFailedInstallationReleasesTheEntryPoints() async throws {
        let model = AppModel()

        do {
            try await model.installPandoc(brewExecutable: Self.brewExecutable) { _ in
                throw InstallationFailure()
            }
            XCTFail("Der Fehler der Installation kam nicht bei der App an.")
        } catch is InstallationFailure {
            // erwartet
        }

        XCTAssertFalse(model.isInstallingPandoc)
        XCTAssertTrue(model.acceptsNewDocuments)

        var panelWasPresented = false
        model.chooseDocument {
            panelWasPresented = true
            return nil
        }
        XCTAssertTrue(panelWasPresented, "Die Dokumentauswahl blieb nach dem Fehlschlag gesperrt.")
    }

    /// Nur ein Pfad zu einem Homebrew, das die Testattrappe nie aufruft.
    private static let brewExecutable = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

    /// Wartet, bis die Bedingung zutrifft: die Installation startet in einer
    /// eigenen Task und ist deshalb nicht sofort nach dem Aufruf sichtbar.
    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Zeitüberschreitung, während erwartet wurde, dass \(description).")
    }
}

/// Hält die vorgetäuschte Installation an, bis der Test sie freigibt. So bleibt
/// der Zustand „Installation läuft" für die Prüfungen stehen, ohne einen Thread
/// zu blockieren.
private actor InstallationGate {
    private var isReleased = false
    private var waiting: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        if isReleased {
            return
        }
        await withCheckedContinuation { continuation in
            waiting = continuation
        }
    }

    func release() {
        isReleased = true
        waiting?.resume()
        waiting = nil
    }
}

/// Zählt die wirklich ausgeführten Installationen über Taskgrenzen hinweg.
private actor InstallationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private struct InstallationFailure: Error {}
