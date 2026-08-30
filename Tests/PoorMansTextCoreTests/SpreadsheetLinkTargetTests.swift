import Foundation
import XCTest
@testable import PoorMansTextCore

/// Die Schemaprüfung entscheidet, welches Linkziel aus einer fremden Tabelle
/// als Markdown-Link im Ergebnis stehen darf.
final class SpreadsheetLinkTargetTests: XCTestCase {
    func testKeepsTheUsualWebAndMailAndFileTargets() {
        for target in [
            "https://example.com/a",
            "http://example.com",
            "HTTPS://example.com/gross",
            "mailto:jemand@example.com",
            "file:///Users/beispiel/datei.pdf",
        ] {
            XCTAssertEqual(SpreadsheetLinkTarget.accepted(target), target, target)
        }
    }

    func testKeepsTargetsWithoutAScheme() {
        // Ein relativer Pfad neben der Arbeitsmappe und ein blattinternes Ziel
        // tragen kein Schema und bleiben erlaubt.
        XCTAssertEqual(SpreadsheetLinkTarget.accepted("berichte/2026.pdf"), "berichte/2026.pdf")
        XCTAssertEqual(SpreadsheetLinkTarget.accepted("#Tabelle1.A1"), "#Tabelle1.A1")
        XCTAssertEqual(SpreadsheetLinkTarget.accepted("ordner/a:b.txt"), "ordner/a:b.txt")
    }

    /// Einbuchstabige Schemata sind nach RFC 3986 gültig. Ein fremdes Ziel kann
    /// deshalb nicht allein aufgrund seiner Form als Windows-Pfad durch die
    /// Allowlist gelangen; unbekannte Handler werden geschlossen abgelehnt.
    func testRejectsOneLetterSchemesAndWindowsDriveTargets() {
        XCTAssertNil(SpreadsheetLinkTarget.accepted(#"C:\Berichte\2026.xlsx"#))
        XCTAssertNil(SpreadsheetLinkTarget.accepted("D:/Daten/a.pdf"))
        XCTAssertNil(SpreadsheetLinkTarget.accepted("x:/payload"))
    }

    func testRejectsExecutableAndEmbeddedSchemes() {
        for target in [
            "javascript:alert(1)",
            "JavaScript:alert(1)",
            "  javascript:alert(1)  ",
            "data:text/html;base64,PHNjcmlwdD4=",
            "vbscript:msgbox(1)",
        ] {
            XCTAssertNil(SpreadsheetLinkTarget.accepted(target), target)
        }
    }

    func testRejectsControlCharactersThatCouldHideAScheme() {
        XCTAssertNil(SpreadsheetLinkTarget.accepted("java\u{0A}script:alert(1)"))
        XCTAssertNil(SpreadsheetLinkTarget.accepted("java\u{00}script:alert(1)"))
    }

    func testRejectsAnEmptyTarget() {
        XCTAssertNil(SpreadsheetLinkTarget.accepted(""))
        XCTAssertNil(SpreadsheetLinkTarget.accepted("   "))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(SpreadsheetLinkTarget.accepted("  https://example.com  "), "https://example.com")
    }
}
