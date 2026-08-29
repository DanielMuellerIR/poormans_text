import Foundation
import XCTest
@testable import PoorMansTextCore

/// `MarkdownEscaping` ist die gemeinsame Stelle, an der Text aus einem
/// Quelldokument daran gehindert wird, im Ergebnis neue Markdown-Struktur zu
/// bilden. PDF-Seitentext, OCR-Text und Abschnittsnamen laufen hier durch.
final class MarkdownEscapingTests: XCTestCase {
    func testSetextUnderlinesCannotTurnATextLineIntoAHeading() {
        let escaped = MarkdownEscaping.literalBlock("Titel\n=====\nText")

        XCTAssertEqual(escaped, "Titel\n\\=====\nText")
    }

    func testTildeFencesCannotOpenACodeBlock() {
        let escaped = MarkdownEscaping.literalBlock("~~~\nnoch Text")

        XCTAssertEqual(escaped, "\\~~~\nnoch Text")
    }

    func testOrdinaryTextStaysUntouched() {
        let escaped = MarkdownEscaping.literalBlock("Ein ganz gewöhnlicher Satz.")

        XCTAssertEqual(escaped, "Ein ganz gewöhnlicher Satz.")
    }

    func testExistingBlockMarkersStayEscaped() {
        let escaped = MarkdownEscaping.literalBlock("# Keine Überschrift\n- kein Listenpunkt")

        XCTAssertEqual(escaped, "\\# Keine Überschrift\n\\- kein Listenpunkt")
    }
}
