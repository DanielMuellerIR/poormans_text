import Foundation
import XCTest
@testable import PoorMansTextCore

final class MarkdownContainerLinksRegressionTests: XCTestCase {
    func testOrderedListStartingAtTwoContinuesAnOpenParagraph() {
        let markdown = """
        `code
        2. [inside](images/old.png)
        ` [outside](images/old.png)
        """
        XCTAssertEqual(
            rewrite(markdown),
            """
            `code
            2. [inside](images/old.png)
            ` [outside](images/new.png)
            """
        )
    }

    func testOrderedListInANewBlockquoteStillEndsTheOuterParagraph() {
        let markdown = """
        `literal
        > 2. [outside](images/old.png)
        """
        XCTAssertEqual(
            rewrite(markdown),
            """
            `literal
            > 2. [outside](images/new.png)
            """
        )
    }

    func testOrderedListAfterLeavingAListEndsTheListParagraph() {
        let markdown = """
        - `literal
        2. [outside](images/old.png)
        """
        XCTAssertEqual(
            rewrite(markdown),
            """
            - `literal
            2. [outside](images/new.png)
            """
        )
    }

    func testNestedListFenceKeepsItsLiteralLink() {
        let markdown = """
        - - ~~~
            [inside](images/old.png)
            ~~~
        [outside](images/old.png)
        """
        XCTAssertEqual(
            rewrite(markdown),
            """
            - - ~~~
                [inside](images/old.png)
                ~~~
            [outside](images/new.png)
            """
        )
    }

    func testGFMHTMLBlocksRemainLiteral() {
        let markdown = """
        <pre>
        [pre](images/old.png)
        </pre>
        [after-pre](images/old.png)

        <!--
        [comment](images/old.png)
        -->
        [after-comment](images/old.png)

        <div>
        [div](images/old.png)
        </div>

        [after-div](images/old.png)
        """
        let rewritten = rewrite(markdown)
        XCTAssertTrue(rewritten.contains("[pre](images/old.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[comment](images/old.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[div](images/old.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[after-pre](images/new.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[after-comment](images/new.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[after-div](images/new.png)"), rewritten)
    }

    func testMarkerTerminatedGFMHTMLBlocksRemainLiteral() {
        let markdown = """
        <?target data?>
        [after-processing](images/old.png)

        <!DOCTYPE html>
        [after-declaration](images/old.png)

        <![CDATA[
        [cdata](images/old.png)
        ]]>
        [after-cdata](images/old.png)
        """
        let rewritten = rewrite(markdown)
        XCTAssertTrue(rewritten.contains("[after-processing](images/new.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[after-declaration](images/new.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[cdata](images/old.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[after-cdata](images/new.png)"), rewritten)
    }

    func testLowercaseCDATAIsOrdinaryMarkdown() {
        let markdown = """
        <![cdata[
        [real](images/old.png)
        ]]>
        """
        XCTAssertTrue(rewrite(markdown).contains("[real](images/new.png)"))
    }

    func testGenericHTMLBlockStartsAfterLeavingMarkdownContainers() {
        let markdown = """
        > paragraph
        <x-widget>
        [quote-dedent](images/old.png)

        - paragraph
        <x-widget>
        [list-dedent](images/old.png)
        """
        let rewritten = rewrite(markdown)
        XCTAssertTrue(rewritten.contains("[quote-dedent](images/old.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[list-dedent](images/old.png)"), rewritten)
    }

    func testGenericHTMLAfterListDedentStopsInlineCodeLookahead() {
        let markdown = """
        - ` [real](images/old.png)
        <x-widget>
        `
        [inside](images/old.png)
        """
        let rewritten = rewrite(markdown)
        XCTAssertTrue(rewritten.contains("` [real](images/new.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[inside](images/old.png)"), rewritten)
    }

    func testIndentedAndNearMatchHTMLTextDoesNotOpenAnHTMLBlock() {
        let markdown = """
            <pre>
            [indented-code](images/old.png)

        <div.custom>
        [near-match](images/old.png)
        """
        let rewritten = rewrite(markdown)
        XCTAssertTrue(rewritten.contains("[indented-code](images/old.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[near-match](images/new.png)"), rewritten)
    }

    func testGenericHTMLBlockStartsOnlyOutsideAnOpenParagraph() {
        let markdown = """
        paragraph
        <custom-tag>
        [paragraph-link](images/old.png)

        <custom-tag>
        [html-link](images/old.png)

        [outside](images/old.png)
        """
        let rewritten = rewrite(markdown)
        XCTAssertTrue(rewritten.contains("[paragraph-link](images/new.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[html-link](images/old.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[outside](images/new.png)"), rewritten)
    }

    func testGenericHTMLBlockMayStartInANewListContainer() {
        let markdown = """
        outer paragraph
        - <x-widget>
          [inside](images/old.png)

        [outside](images/old.png)
        """
        let rewritten = rewrite(markdown)
        XCTAssertTrue(rewritten.contains("[inside](images/old.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[outside](images/new.png)"), rewritten)
    }

    func testSelfClosingPreTagDoesNotInterruptAnOpenParagraph() {
        let markdown = """
        paragraph
        <pre/>
        [real](images/old.png)
        """
        XCTAssertTrue(rewrite(markdown).contains("[real](images/new.png)"))
    }

    func testUnclosedHTMLBlockEndsWithItsBlockquoteContainer() {
        let markdown = """
        > <pre>
        > [inside](images/old.png)
        [outside](images/old.png)
        """
        XCTAssertEqual(
            rewrite(markdown),
            """
            > <pre>
            > [inside](images/old.png)
            [outside](images/new.png)
            """
        )
    }

    func testMarkdownContainerMarkersInsideHTMLRemainLiteral() {
        let rootHTML = """
        <pre>
        > [inside](images/old.png)
        </pre>

        [outside](images/old.png)
        """
        let listHTML = """
        - <div>
          - [inside](images/old.png)

        [outside](images/old.png)
        """
        let rewrittenRoot = rewrite(rootHTML)
        let rewrittenList = rewrite(listHTML)
        XCTAssertTrue(rewrittenRoot.contains("> [inside](images/old.png)"), rewrittenRoot)
        XCTAssertTrue(rewrittenRoot.contains("[outside](images/new.png)"), rewrittenRoot)
        XCTAssertTrue(rewrittenList.contains("- [inside](images/old.png)"), rewrittenList)
        XCTAssertTrue(rewrittenList.contains("[outside](images/new.png)"), rewrittenList)
    }

    func testInterruptingHTMLBlockStopsInlineCodeLookahead() {
        let markdown = """
        ` [real](images/old.png)
        <pre>`
        [inside](images/old.png)
        </pre>
        """
        let rewritten = rewrite(markdown)
        XCTAssertTrue(rewritten.contains("` [real](images/new.png)"), rewritten)
        XCTAssertTrue(rewritten.contains("[inside](images/old.png)"), rewritten)
    }

    private func rewrite(_ markdown: String) -> String {
        MarkdownLinkTargetRewriter.replacing(
            in: markdown,
            from: "images/old.png",
            to: "images/new.png"
        )
    }

    func testInlineHTMLDoesNotExposeMarkdownExamplesAsLinks() throws {
        let markdown = #"Text <span title="[x](old.png)">text</span> <!-- [x](old.png) --> [real](old.png)"#
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: markdown, mapping: ["old.png": "new.png"]),
            #"Text <span title="[x](old.png)">text</span> <!-- [x](old.png) --> [real](new.png)"#)
    }

    func testListThenQuoteFenceKeepsItsLiteralLinks() throws {
        let markdown = "- > ~~~\n  > [literal](old.png)\n  > ~~~\n\n[real](old.png)"
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: markdown, mapping: ["old.png": "new.png"]),
            "- > ~~~\n  > [literal](old.png)\n  > ~~~\n\n[real](new.png)")
    }

    func testMixedContainerOrderProtectsCodeAndHTMLAndEndsAtItsOwnBoundary() {
        for opener in ["~~~", "<pre>"] {
            let close = opener == "~~~" ? "~~~" : "</pre>"
            for (prefix, continuation) in [("- > - > ", "  >   > "), ("> - > - ", ">   >   ")] {
                let input = prefix + opener + "\n" + continuation + "[literal](old.png)\n" + continuation + close + "\n\n[real](old.png)"
                XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: input, mapping: ["old.png": "new.png"]),
                    input.replacingOccurrences(of: "[real](old.png)", with: "[real](new.png)"))
            }
        }
        let unclosed = "- > ~~~\n  > [literal](old.png)\n\n[real](old.png)"
        XCTAssertTrue(MarkdownLinkTargetRewriter.replacing(in: unclosed, mapping: ["old.png": "new.png"]).hasSuffix("[real](new.png)"))
    }

    func testCodeMarkersCannotHideSubsequentInlineHTMLFromTheScanner() {
        let input = #"`<!--` <span title="[x](old.png)">ok</span> --> [real](old.png)"#
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: input, mapping: ["old.png": "new.png"]),
            input.replacingOccurrences(of: "[real](old.png)", with: "[real](new.png)"))
        let container = "- > text\n  > ~~~\n> [real](old.png)"
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: container, mapping: ["old.png": "new.png"]),
            container.replacingOccurrences(of: "[real](old.png)", with: "[real](new.png)"))
    }
}
