import Foundation
import XCTest
@testable import PoorMansTextCore

/// Regressionen für die 17 Funde des Nacht-Reviews vom 2026-08-30.
final class ReviewFixes20260830Tests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextReviewFixes0830-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testPrivateFileCopyKeepsTheVerifiedBytesAfterTheSourceIsReplaced() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        try Data("first".utf8).write(to: source)

        let snapshotText = try VerifiedFileStaging.withTemporaryCopy(
            of: source,
            maximumBytes: 100,
            describedAs: "the test source",
            fileExtension: "pdf"
        ) { snapshot in
            try FileManager.default.removeItem(at: source)
            try Data("second".utf8).write(to: source)
            return try String(contentsOf: snapshot, encoding: .utf8)
        }

        XCTAssertEqual(snapshotText, "first")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "second")
    }

    func testRTFDSnapshotRejectsAnEmbeddedSymbolicLink() throws {
        let package = temporaryDirectory.appendingPathComponent("Unsafe.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let outside = temporaryDirectory.appendingPathComponent("outside.rtf")
        try Data(#"{\rtf1\ansi outside}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("TXT.rtf"),
            withDestinationURL: outside
        )

        let detection = try RichTextAdapter().inspectInput(at: package)
        guard case .invalid(.rtfd, _, let reason) = detection else {
            return XCTFail("Unexpected detection: \(detection)")
        }
        XCTAssertTrue(reason.contains("symbolic link"), reason)
    }

    func testRTFDSnapshotUsesOneTotalByteBudget() throws {
        let package = temporaryDirectory.appendingPathComponent("Large.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 6).write(to: package.appendingPathComponent("a"))
        try Data(repeating: 2, count: 6).write(to: package.appendingPathComponent("b"))
        let snapshot = temporaryDirectory.appendingPathComponent("snapshot.rtfd", isDirectory: true)

        XCTAssertThrowsError(
            try VerifiedDirectoryStaging.stage(
                from: package,
                to: snapshot,
                maximumFileBytes: 10,
                maximumTotalBytes: 10,
                maximumEntries: 10,
                describedAs: "the test package"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("size limit"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    }

    func testLegacyWordDetectionRejectsOversizedInputBeforeTextutil() throws {
        let source = temporaryDirectory.appendingPathComponent("Oversized.doc")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]).write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 1_073_741_825)
        try handle.close()

        let detection = try LegacyWordAdapter().inspectInput(at: source)
        guard case .invalid(.doc, _, let reason) = detection else {
            return XCTFail("Unexpected detection: \(detection)")
        }
        XCTAssertTrue(reason.contains("size limit"), reason)
    }

    func testNarrowImageBudgetAccountsForTheOnePixelMinimumEdge() {
        XCTAssertEqual(
            ImageOCRBudget.maximumEdge(width: 100_000, height: 1, budget: 64_000),
            64_000
        )
        XCTAssertNil(ImageOCRBudget.maximumEdge(width: 200, height: 100, budget: 20_000))
    }

    func testCompressedZIPMetadataIsBoundedBeforeItsInputSlice() throws {
        let archiveURL = temporaryDirectory.appendingPathComponent("metadata.zip")
        let archive = try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "mimetype",
                content: Data("x".utf8),
                declaredUncompressedSize: 1,
                declaredCompressedSize: 16_777_217,
                isStored: true
            ),
        ])
        try archive.write(to: archiveURL)

        XCTAssertThrowsError(
            try ZIPArchiveInspector.packageContents(at: archiveURL, entryNames: ["mimetype"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("compressed package metadata"))
        }
    }

    func testSpreadsheetNamesAndLiteralCellsCannotCreateMarkdownResources() throws {
        let cellText = "![Bild](https://host/x) <img src=\"https://host/y\">"
        let workbook = SpreadsheetWorkbook(sheets: [
            SpreadsheetSheet(
                name: "![Blatt](https://host/s)",
                rows: [[SpreadsheetCell(value: .string(cellText), displayText: cellText, formula: nil)]]
            ),
        ])
        let markdown = try SpreadsheetMarkdownRenderer.render(
            workbook,
            sourceURL: URL(fileURLWithPath: "/tmp/![Datei](https-host).xlsx"),
            style: .markdownTable
        )

        XCTAssertFalse(markdown.contains("![Bild]("), markdown)
        XCTAssertFalse(markdown.contains("| <img"), markdown)
        XCTAssertTrue(markdown.contains(#"\<img"#), markdown)
        XCTAssertFalse(markdown.contains("![Blatt]("), markdown)
        XCTAssertTrue(markdown.contains(#"\!\[Bild\]\(https://host/x\)"#), markdown)
    }

    func testLinkTitleBackticksDoNotHideTheFollowingAssetLink() {
        let markdown = #"[first](images/old.png "title ` literal") [second](images/old.png) `later`"#
        XCTAssertEqual(
            rewrite(markdown),
            #"[first](images/new.png "title ` literal") [second](images/new.png) `later`"#
        )
    }

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

    func testManySingleLineCodeSpansDoNotRescanTheRemainingParagraph() {
        let line = "`code` [asset](images/old.png)"
        let markdown = Array(repeating: line, count: 5_000).joined(separator: "\n")
        let rewritten = rewrite(markdown)
        XCTAssertEqual(rewritten.components(separatedBy: "images/new.png").count - 1, 5_000)
    }

    func testPDFFailureWarningAllowsForPreservedFallbackText() {
        XCTAssertTrue(ConversionWarning.pdfOCRFailed.message.contains("fallback text"))
        XCTAssertFalse(ConversionWarning.pdfOCRFailed.message.contains("without text"))
    }

    private func rewrite(_ markdown: String) -> String {
        MarkdownLinkTargetRewriter.replacing(
            in: markdown,
            from: "images/old.png",
            to: "images/new.png"
        )
    }
}
