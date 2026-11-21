import Foundation
import XCTest
@testable import PoorMansTextCore

final class AdapterSourceInvariantsRegressionTests: XCTestCase {
    func testXLSDetectionDoesNotMapTheForeignSource() throws {
        // Der Beleg im Quelltext: Die Erkennung darf die fremde Datei nicht mehr
        // abbilden. Ein echter SIGBUS lässt sich in einem Test nicht auslösen,
        // ohne den Testprozess mitzunehmen.
        let adapter = try String(
            contentsOf: RegressionFixtures.projectRoot.appendingPathComponent(
                "Sources/PoorMansTextCore/Formats/Spreadsheets/SpreadsheetAdapter.swift"
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

    /// Alle Adapter stagen über `context.resolvedInputURL`. Mit dem symbolischen
    /// `inputURL` konnte ein Verweis nach der Erkennung, aber vor dem Staging
    /// umgehängt werden — der Adapter las dann ein anderes Dokument als das
    /// geprüfte.
    func testAdaptersStageFromTheResolvedSource() throws {
        for name in [
            "Formats/RichText/RichTextConverter.swift",
            "Formats/WordProcessing/WordProcessingPackageAdapter.swift",
            "Formats/WordProcessing/LegacyWordAdapter.swift",
            "Formats/Spreadsheets/SpreadsheetAdapter.swift",
        ] {
            let quelle = try String(
                contentsOf: RegressionFixtures.projectRoot.appendingPathComponent("Sources/PoorMansTextCore/\(name)"),
                encoding: .utf8
            )
            XCTAssertFalse(quelle.contains("from: context.inputURL,"),
                           "\(name) stagt noch über den symbolischen Pfad")
        }
    }

    func testMasterAdapterUsesTheSharedHeadingEscaping() throws {
        let quelle = try String(
            contentsOf: RegressionFixtures.projectRoot.appendingPathComponent(
                "Sources/PoorMansTextCore/Formats/OpenDocument/OpenDocumentMasterAdapter.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(quelle.contains("func headingText("),
                       "Der lokale Zwilling von MarkdownEscaping.heading ist wieder da")
        XCTAssertTrue(quelle.contains("MarkdownEscaping.heading("))
    }
}
