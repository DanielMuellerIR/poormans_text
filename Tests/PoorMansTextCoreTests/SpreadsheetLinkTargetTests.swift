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
