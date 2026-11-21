import CoreGraphics
import Foundation
import XCTest
@testable import PoorMansTextCore

final class VisionReadingOrderRegressionTests: XCTestCase {
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

    private func line(_ text: String, midY: CGFloat, minX: CGFloat)
        -> VisionTextRecognizer.OCRLine {
        // Vision liefert normalisierte Rechtecke mit Ursprung unten links.
        let hoehe: CGFloat = 0.01
        return VisionTextRecognizer.OCRLine(
            text: text,
            bounds: CGRect(x: minX, y: midY - hoehe / 2, width: 0.2, height: hoehe)
        )
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
}
