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
    func testInstallationCannotStartDuringARealConversion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.csv")
        let original = Data("name,value\nTOKEN,42\n".utf8)
        try original.write(to: input)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.convert(input)
        XCTAssertTrue(model.isConverting)
        let counter = InstallationCounter()
        let performed = try await model.installPandoc(brewExecutable: Self.brewExecutable) { _, _ in
            await counter.increment()
        }
        XCTAssertFalse(performed)
        let runs = await counter.count
        XCTAssertEqual(runs, 0)
        try await waitUntil("die Umwandlung beendet ist") { !model.isConverting }
        guard case .succeeded(let result) = model.state else { return XCTFail("Conversion failed") }
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("TOKEN"))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    @MainActor
    func testEveryEntryPointIsBlockedWhilePandocIsInstalling() async throws {
        let model = AppModel(defaults: .isolatedForAppTest())
        let gate = InstallationGate()
        let document = URL(fileURLWithPath: "/tmp/PoorMansTextNeverConverted.rtf")

        let installation = Task {
            try await model.installPandoc(brewExecutable: Self.brewExecutable) { _, _ in
                await gate.waitForRelease()
            }
        }
        try await waitUntil("die Installation läuft") { model.isInstallingPandoc }
        XCTAssertFalse(model.acceptsNewDocuments)

        // Einstieg 1: Dock, Doppelklick und `open -a` kommen über
        // `openDocuments` an. Der Weg meldet die Sperre jetzt im Fenster;
        // vorher schwieg er (Roadmap-Punkt, 2026-09-10).
        XCTAssertFalse(model.openDocuments([document]), "Das Öffnen wurde trotz laufender Installation angenommen.")
        XCTAssertFalse(model.isConverting, "Die Umwandlung lief trotz laufender Installation an.")
        XCTAssertEqual(model.openRejectionMessage, "Files are accepted again once the installation has finished.")
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
            return [document]
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
        let model = AppModel(defaults: .isolatedForAppTest())
        let gate = InstallationGate()
        let counter = InstallationCounter()

        let installation = Task {
            try await model.installPandoc(brewExecutable: Self.brewExecutable) { _, _ in
                await counter.increment()
                await gate.waitForRelease()
            }
        }
        try await waitUntil("die Installation läuft") { model.isInstallingPandoc }

        let second = try await model.installPandoc(brewExecutable: Self.brewExecutable) { _, _ in
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
        let model = AppModel(defaults: .isolatedForAppTest())

        do {
            try await model.installPandoc(brewExecutable: Self.brewExecutable) { _, _ in
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
            return []
        }
        XCTAssertTrue(panelWasPresented, "Die Dokumentauswahl blieb nach dem Fehlschlag gesperrt.")
    }

    /// Ein Abbruch aus der Oberfläche erreicht den Token der Installation,
    /// gilt nicht als Fehler und gibt alle Einstiege wieder frei. Vorher
    /// kannte die Installation weder Token noch Abbruchknopf: Ein hängendes
    /// Homebrew sperrte die App bis zum Neustart (Roadmap-Punkt, 2026-09-10).
    @MainActor
    func testCancellingTheInstallationReachesTheTokenAndReleasesTheEntryPoints() async throws {
        let model = AppModel(defaults: .isolatedForAppTest())

        let installation = Task {
            try await model.installPandoc(brewExecutable: Self.brewExecutable) { _, cancellation in
                // Die Attrappe verhält sich wie `brew`: Sie läuft, bis der Token
                // sie beendet, und meldet das als Abbruch.
                while !cancellation.isCancelled {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw PandocInstaller.InstallError.cancelled
            }
        }
        try await waitUntil("die Installation läuft") { model.isInstallingPandoc }
        XCTAssertFalse(model.isCancellingPandocInstallation)

        model.cancelPandocInstallation()
        XCTAssertTrue(model.isCancellingPandocInstallation, "Der Abbruchknopf sperrte sich nicht.")

        let performed = try await installation.value
        XCTAssertFalse(performed, "Ein abgebrochener Lauf meldete eine abgeschlossene Installation.")
        XCTAssertFalse(model.isInstallingPandoc)
        XCTAssertFalse(model.isCancellingPandocInstallation)
        XCTAssertTrue(model.acceptsNewDocuments)

        // Ohne laufende Installation ist der Abbruch wirkungslos.
        model.cancelPandocInstallation()
        XCTAssertFalse(model.isCancellingPandocInstallation)
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
