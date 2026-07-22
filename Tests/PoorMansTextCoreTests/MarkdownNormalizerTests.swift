import XCTest
@testable import PoorMansTextCore

final class MarkdownNormalizerTests: XCTestCase {
    func testUsesTwoSpacesForPandocHardBreaksAndRemovesEmptyEmphasis() {
        let markdown = "Text\\\n\n****\\\n\nNext\n"

        XCTAssertEqual(
            MarkdownNormalizer.normalize(markdown),
            "Text  \n  \nNext\n"
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
