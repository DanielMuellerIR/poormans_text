import CoreGraphics
import Foundation
import XCTest
@testable import PoorMansTextCore

/// Regressionstests zu den Funden des Nacht-Reviews vom 2026-08-25.
final class ReviewFixes20260825Tests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextReviewFixes0825-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Fremde Quellen werden gelesen, nicht abgebildet

    /// Die XLS-Erkennung bildete eine fremde Datei bis 1 GiB mit
    /// `.mappedIfSafe` ab. Kürzt ein Abgleichdienst sie danach, beendet SIGBUS
    /// den ganzen Prozess — kein `catch` fängt das ab. Gelesen wird jetzt über
    /// genau einen Deskriptor, ohne Abbildung.
    func testVerifiedReadReturnsTheContentsWithoutMapping() throws {
        let source = temporaryDirectory.appendingPathComponent("quelle.bin")
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        try payload.write(to: source)

        let gelesen = try VerifiedFileStaging.contents(
            of: source,
            maximumBytes: 1_048_576,
            describedAs: "the test source"
        )
        XCTAssertEqual(gelesen, payload)
    }

    func testVerifiedReadRejectsASourceAboveTheBudget() throws {
        let source = temporaryDirectory.appendingPathComponent("zu-gross.bin")
        try Data(repeating: 0x41, count: 2048).write(to: source)

        XCTAssertThrowsError(
            try VerifiedFileStaging.contents(
                of: source,
                maximumBytes: 1024,
                describedAs: "the test source"
            )
        ) { error in
            guard let staging = error as? VerifiedFileStaging.StagingError else {
                return XCTFail("Erwartet wird ein StagingError, nicht \(error)")
            }
            XCTAssertEqual(staging.kind, .source)
        }
    }

    func testVerifiedReadRejectsADirectory() throws {
        XCTAssertThrowsError(
            try VerifiedFileStaging.contents(
                of: temporaryDirectory,
                maximumBytes: 1_048_576,
                describedAs: "the test source"
            )
        )
    }

    func testXLSDetectionDoesNotMapTheForeignSource() throws {
        // Der Beleg im Quelltext: Die Erkennung darf die fremde Datei nicht mehr
        // abbilden. Ein echter SIGBUS lässt sich in einem Test nicht auslösen,
        // ohne den Testprozess mitzunehmen.
        let adapter = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/PoorMansTextCore/SpreadsheetAdapter.swift"
            ),
            encoding: .utf8
        )
        // Abgebildet werden darf ausschliesslich die eigene, gerade selbst
        // geschriebene Arbeitskopie — jede `.mappedIfSafe`-Stelle muss deshalb
        // `stagedInput` als Quelle nennen.
        let abbildungen = adapter.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .filter { $0.contains(".mappedIfSafe") }
        XCTAssertFalse(abbildungen.isEmpty, "Die Stelle für die Arbeitskopie fehlt")
        for zeile in abbildungen {
            XCTAssertTrue(zeile.contains("stagedInput"),
                          "Abgebildet wird eine fremde Quelle: \(zeile)")
        }
        XCTAssertTrue(adapter.contains("VerifiedFileStaging.contents("),
                      "Die Erkennung liest die fremde Quelle über genau einen Deskriptor")
    }

    // MARK: - Leserichtung der Vision-Zeilen

    /// Der frühere Comparator verglich bei kleinem Y-Abstand X und sonst Y. Für
    /// drei Zeilen mit den Y-Werten 0, 0.01 und 0.02 und steigendem X gilt damit
    /// A < B, B < C und zugleich C < A — keine strikte schwache Ordnung.
    /// `sorted(by:)` durfte darauf mit beliebiger Reihenfolge antworten.
    func testReadingOrderStaysStableOnAnIntransitiveTriple() {
        // Der Ringschluss aus dem Befund: A und B sowie B und C liegen je
        // innerhalb der Toleranz von 0,015 (dort entschied X), A und C nicht
        // (dort entschied Y). Mit steigendem X bei steigendem Y ergab das
        // A < B, B < C UND C < A. Fuer so eine Vorschrift darf `sorted(by:)`
        // jede beliebige Reihenfolge liefern — auch je nach Eingabereihenfolge
        // eine andere.
        let zeilen = [
            line("A", midY: 0.900, minX: 0.10),
            line("B", midY: 0.910, minX: 0.50),
            line("C", midY: 0.920, minX: 0.90),
        ]
        var ergebnisse = Set<[String]>()
        for reihenfolge in permutationen(zeilen) {
            ergebnisse.insert(VisionTextRecognizer.readingOrder(reihenfolge).map(\.text))
        }
        XCTAssertEqual(ergebnisse.count, 1,
                       "Die Leserichtung haengt von der Eingabereihenfolge ab: \(ergebnisse)")
        // Und zwar die Baender von oben nach unten: C und B liegen im selben
        // Band (Abstand 0,010), A faellt mit 0,020 darunter.
        XCTAssertEqual(ergebnisse.first, ["B", "C", "A"])
    }

    private func permutationen(
        _ zeilen: [VisionTextRecognizer.OCRLine]
    ) -> [[VisionTextRecognizer.OCRLine]] {
        guard zeilen.count > 1 else { return [zeilen] }
        var alle: [[VisionTextRecognizer.OCRLine]] = []
        for index in zeilen.indices {
            var rest = zeilen
            let kopf = rest.remove(at: index)
            for schwanz in permutationen(rest) {
                alle.append([kopf] + schwanz)
            }
        }
        return alle
    }

    func testReadingOrderSortsOneBandLeftToRight() {
        let zeilen = [
            line("rechts", midY: 0.900, minX: 0.80),
            line("mitte", midY: 0.902, minX: 0.40),
            line("links", midY: 0.898, minX: 0.05),
        ]
        let geordnet = VisionTextRecognizer.readingOrder(zeilen).map(\.text)
        XCTAssertEqual(geordnet, ["links", "mitte", "rechts"])
    }

    func testReadingOrderIsIndependentOfTheInputOrder() {
        let zeilen = [
            line("Kopf", midY: 0.950, minX: 0.10),
            line("Zeile links", midY: 0.500, minX: 0.10),
            line("Zeile rechts", midY: 0.503, minX: 0.60),
            line("Fuss", midY: 0.050, minX: 0.10),
        ]
        let erwartet = ["Kopf", "Zeile links", "Zeile rechts", "Fuss"]
        for start in zeilen.indices {
            let gedreht = Array(zeilen[start...] + zeilen[..<start])
            XCTAssertEqual(VisionTextRecognizer.readingOrder(gedreht).map(\.text), erwartet,
                           "Die Reihenfolge darf nicht von der Eingabereihenfolge abhängen")
        }
    }

    // MARK: - Staging bindet an die aufgelöste Quelle

    /// Alle Adapter stagen über `context.resolvedInputURL`. Mit dem symbolischen
    /// `inputURL` konnte ein Verweis nach der Erkennung, aber vor dem Staging
    /// umgehängt werden — der Adapter las dann ein anderes Dokument als das
    /// geprüfte.
    func testAdaptersStageFromTheResolvedSource() throws {
        for name in [
            "RichTextConverter.swift",
            "WordProcessingPackageAdapter.swift",
            "LegacyWordAdapter.swift",
            "SpreadsheetAdapter.swift",
        ] {
            let quelle = try String(
                contentsOf: projectRoot.appendingPathComponent("Sources/PoorMansTextCore/\(name)"),
                encoding: .utf8
            )
            XCTAssertFalse(quelle.contains("from: context.inputURL,"),
                           "\(name) stagt noch über den symbolischen Pfad")
        }
    }

    // MARK: - Nur eine Fassung der Überschriften-Maskierung

    func testMasterAdapterUsesTheSharedHeadingEscaping() throws {
        let quelle = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/PoorMansTextCore/OpenDocumentMasterAdapter.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(quelle.contains("func headingText("),
                       "Der lokale Zwilling von MarkdownEscaping.heading ist wieder da")
        XCTAssertTrue(quelle.contains("MarkdownEscaping.heading("))
    }

    // MARK: - Hilfen

    private func line(_ text: String, midY: CGFloat, minX: CGFloat)
        -> VisionTextRecognizer.OCRLine {
        // Vision liefert normalisierte Rechtecke mit Ursprung unten links.
        let hoehe: CGFloat = 0.01
        return VisionTextRecognizer.OCRLine(
            text: text,
            bounds: CGRect(x: minX, y: midY - hoehe / 2, width: 0.2, height: hoehe)
        )
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
