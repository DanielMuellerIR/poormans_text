import XCTest
@testable import PoorMansTextCore

final class MarkdownNormalizerTests: XCTestCase {
    func testUsesTwoSpacesForPandocHardBreaksAndRemovesEmptyEmphasis() {
        let markdown = "Text\\\ncontinued\n\n****\\\n\nNext\n"

        XCTAssertEqual(
            MarkdownNormalizer.normalize(markdown),
            "Text  \ncontinued\n  \nNext\n"
        )
    }

    func testDropsLayoutOnlyHardBreaksBeforeBlankListAndDocumentEnd() {
        let markdown = "Paragraph\\\n\nBefore list\\\n- item\nEnd\\"

        XCTAssertEqual(
            MarkdownNormalizer.normalize(markdown),
            "Paragraph\n\nBefore list\n- item\nEnd"
        )
    }

    func testNormalizesTypedBulletsLeadingHyphensAndSeparators() {
        let markdown = "***• ***\n\n***• ***\n\n\\- item\n\n\\_\\_\\_\\_\n"

        XCTAssertEqual(
            MarkdownNormalizer.normalize(markdown),
            "-\n-\n\n- item\n\n____\n"
        )
    }

    func testKeepsAdjacentPlainParagraphsSeparate() {
        let markdown = "Intro:\n\nFirst line\n\nSecond line\n\n**Heading**\n"

        XCTAssertEqual(MarkdownNormalizer.normalize(markdown), markdown)
    }

    func testLeavesFencedCodeUnchanged() {
        let markdown = "```text\n\\- item\n\\_\\_\\_\n\\\n```\n"

        XCTAssertEqual(MarkdownNormalizer.normalize(markdown), markdown)
    }

    /// Pandoc schreibt einen Code-Block ohne Sprachangabe eingerückt statt
    /// eingezäunt — auch im GFM-Dialekt. Griffen die Aufräumregeln dort, verlöre
    /// eine Shell-Fortsetzung ihren abschließenden Backslash, und aus `\-` würde
    /// ein Listenpunkt. Das wäre stiller Inhaltsverlust.
    func testLeavesIndentedCodeUnchangedIncludingItsBlankLines() {
        let markdown = """
        Intro:

            gcc -o example example.c \\

            \\- not a list
            \\_\\_\\_

        Done
        """

        XCTAssertEqual(MarkdownNormalizer.normalize(markdown), markdown)
    }

    /// Gegenprobe zur Code-Erkennung: Vier Leerzeichen sind nur dann Code, wenn
    /// sie vier Spalten JENSEITS des offenen Listenpunkts liegen. Sonst wäre
    /// jeder tiefer eingerückte Listeneintrag fälschlich Code.
    func testStillNormalizesIndentedContentInsideAListItem() {
        let markdown = "- item\n\n    ***• ***\n\n    \\- sub item\n"

        XCTAssertEqual(
            MarkdownNormalizer.normalize(markdown),
            "- item\n\n    -\n\n    - sub item\n"
        )
    }

    func testKeepsBlankLinesInsideFencedCode() {
        let markdown = "```text\nfirst\n\n \nlast\n```\n"

        XCTAssertEqual(MarkdownNormalizer.normalize(markdown), markdown)
    }

    func testDoesNotCloseFenceWhenTextFollowsDelimiter() {
        let markdown = #"""
        ````text
        ````not-a-closing-fence
        \- literal
        ````
        """#

        XCTAssertEqual(MarkdownNormalizer.normalize(markdown), markdown)
    }

    func testClosesFenceWithLongerWhitespaceOnlyDelimiter() {
        let markdown = #"""
        ~~~text
        \- code
         ~~~~
        \- prose
        """#
        let expected = #"""
        ~~~text
        \- code
         ~~~~
        - prose
        """#

        XCTAssertEqual(MarkdownNormalizer.normalize(markdown), expected)
    }
}
