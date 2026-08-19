import Foundation
import XCTest
@testable import PoorMansTextCore

final class OpenDocumentMasterAdapterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextODMTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testConvertsLocalLinkedODTDocumentsInMasterOrderWithUniqueAssets() throws {
        try requirePandoc()
        let masterURL = temporaryDirectory.appendingPathComponent("Book.odm")
        try ZIPFixtureBuilder.odmPackage(contentXML: masterContent(
            sections: [
                ("Chapter One", "./chapter-one.odt"),
                ("Chapter Two", "parts/chapter-two.odt"),
            ]
        )).write(to: masterURL)
        let parts = temporaryDirectory.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: false)
        let first = temporaryDirectory.appendingPathComponent("chapter-one.odt")
        let second = parts.appendingPathComponent("chapter-two.odt")
        try FileManager.default.copyItem(at: wordFixture("pandoc.odt"), to: first)
        try FileManager.default.copyItem(at: wordFixture("pandoc.odt"), to: second)
        let sourceBytes = try [masterURL, first, second].map { try Data(contentsOf: $0) }

        let inspection = try DocumentConverter().inspect(masterURL)
        XCTAssertEqual(inspection.format, .odm)
        XCTAssertEqual(inspection.expectedWarnings.map(\.code), ["openDocumentMaster.flattened"])

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: masterURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("master-result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(result.format, .odm)
        XCTAssertTrue(markdown.contains("Master introduction."))
        let firstSection = try XCTUnwrap(markdown.range(of: "## Section: Chapter One"))
        let secondSection = try XCTUnwrap(markdown.range(of: "## Section: Chapter Two"))
        XCTAssertLessThan(firstSection.lowerBound, secondSection.lowerBound)
        XCTAssertEqual(markdown.components(separatedBy: "Fixture heading ä").count - 1, 2)
        XCTAssertTrue(markdown.contains("images/section01-image01.png"))
        XCTAssertTrue(markdown.contains("images/section02-image01.png"))
        XCTAssertEqual(result.assets.map(\.lastPathComponent), [
            "section01-image01.png", "section02-image01.png",
        ])
        XCTAssertEqual(
            try [masterURL, first, second].map { try Data(contentsOf: $0) },
            sourceBytes
        )
    }

    func testResolvesLinkedDocumentsRelativeToTheRealMasterBehindASymbolicLink() throws {
        try requirePandoc()
        // Teildokumente liegen neben dem ECHTEN Master. Wählt der Nutzer einen
        // Verweis darauf aus, darf der Bezugspunkt nicht das Verzeichnis des
        // Verweises sein — dort steht nichts, und der Abschnitt galt als fehlend.
        let bundle = temporaryDirectory.appendingPathComponent("buch", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let masterURL = bundle.appendingPathComponent("Book.odm")
        try ZIPFixtureBuilder.odmPackage(
            contentXML: masterContent(sections: [("Chapter One", "chapter-one.odt")])
        ).write(to: masterURL)
        try FileManager.default.copyItem(
            at: wordFixture("pandoc.odt"),
            to: bundle.appendingPathComponent("chapter-one.odt")
        )

        let linkURL = temporaryDirectory.appendingPathComponent("Verweis.odm")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: masterURL)

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: linkURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("link-result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(result.format, .odm)
        XCTAssertTrue(markdown.contains("## Section: Chapter One"))
        XCTAssertTrue(markdown.contains("Master introduction."))
        // Das Ergebnis gehört weiterhin dorthin, wohin der Aufrufer es bestellt
        // hat, und nicht neben das Original.
        XCTAssertEqual(
            result.outputDirectory.standardizedFileURL,
            temporaryDirectory.appendingPathComponent("link-result").standardizedFileURL
        )
    }

    func testRejectsRemoteTraversalMissingAndEscapingSymlinkReferences() throws {
        let outsideODT = wordFixture("pandoc.odt")
        let escapingLink = temporaryDirectory.appendingPathComponent("escape.odt")
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationURL: outsideODT)

        let cases = [
            ("remote.odm", "https://example.com/chapter.odt", "non-local"),
            ("traversal.odm", "../chapter.odt", "leaves the document bundle"),
            ("missing.odm", "missing.odt", "is missing"),
            ("symlink.odm", "escape.odt", "symbolic link"),
        ]
        for (name, reference, message) in cases {
            let url = temporaryDirectory.appendingPathComponent(name)
            try ZIPFixtureBuilder.odmPackage(
                contentXML: masterContent(sections: [("Section", reference)])
            ).write(to: url)

            XCTAssertThrowsError(try DocumentConverter().inspect(url)) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(message),
                    "Unexpected error for \(reference): \(error.localizedDescription)"
                )
            }
        }
    }

    func testForeignHrefNamespaceDoesNotTurnASectionIntoALinkedDocument() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:foo="urn:example:foreign">
          <office:body><office:text>
            <text:section text:name="Local">
              <text:section-source foo:href="secret.odt"/>
              <text:p>Local section text</text:p>
            </text:section>
          </office:text></office:body>
        </office:document-content>
        """.utf8)

        XCTAssertEqual(
            try ODMContentParser.parse(xml),
            [.markdown("Local section text")]
        )
    }

    /// Eine ODF-Notiz mitten im Absatz enthält selbst wieder `text:p`. Vorher
    /// ersetzte der innere Absatz den äußeren, und der Text davor und danach
    /// verschwand still aus dem Ergebnis.
    func testMasterParagraphKeepsANestedAnnotationParagraphInSourceOrder() throws {
        let markdown = try convertedMasterMarkdown(
            body: """
            <text:p>Before <office:annotation><text:p>Note</text:p></office:annotation> After</text:p>
            """,
            name: "Annotated"
        )

        XCTAssertEqual(markdown, "# Annotated\n\nBefore Note After\n")
    }

    func testAdjacentAnnotationParagraphsKeepSemanticBoundaries() throws {
        let markdown = try convertedMasterMarkdown(
            body: """
            <text:p>Before<office:annotation><text:p>First</text:p><text:p>Second</text:p></office:annotation>After</text:p>
            """,
            name: "TwoNotes"
        )

        XCTAssertEqual(markdown, "# TwoNotes\n\nBefore First Second After\n")
    }

    func testAnnotationParagraphAddsSpacesOnlyBetweenWords() throws {
        let markdown = try convertedMasterMarkdown(
            body: """
            <text:p>Vor<office:annotation><text:p>Notiz</text:p></office:annotation>, danach</text:p>
            <text:p>(<office:annotation><text:p>Klammernotiz</text:p></office:annotation>)</text:p>
            """,
            name: "AnnotationPunctuation"
        )

        XCTAssertEqual(
            markdown,
            "# AnnotationPunctuation\n\nVor Notiz, danach\n\n(Klammernotiz)\n"
        )
    }

    /// Review-Fund 2026-08-17: `needsSpace` verlangte von BEIDEN Seiten einen
    /// Buchstaben oder eine Ziffer. Ein Notizabsatz, der auf Satzendinterpunktion
    /// endet, wurde deshalb ohne Trennung an das folgende Wort geklebt —
    /// `Before Note.After` statt `Before Note. After`. Die beiden Richtungen
    /// gehören getrennt beurteilt.
    func testAnnotationParagraphEndingInPunctuationStillSeparatesTheNextWord() throws {
        let markdown = try convertedMasterMarkdown(
            body: """
            <text:p>Before<office:annotation><text:p>Note.</text:p></office:annotation>After</text:p>
            <text:p>Frage<office:annotation><text:p>Notiz?</text:p></office:annotation>Antwort</text:p>
            """,
            name: "AnnotationSentenceEnd"
        )

        XCTAssertEqual(
            markdown,
            "# AnnotationSentenceEnd\n\nBefore Note. After\n\nFrage Notiz? Antwort\n"
        )
    }

    /// Gegenprobe zur Regel oben: Ein Bindestrich an der Naht darf weiterhin
    /// kein Leerzeichen bekommen — sonst zerfiele ein zusammengesetztes Wort.
    func testAnnotationParagraphKeepsHyphenatedWordsTogether() throws {
        let markdown = try convertedMasterMarkdown(
            body: """
            <text:p>Vor-<office:annotation><text:p>Notiz</text:p></office:annotation>-Nachsatz</text:p>
            """,
            name: "AnnotationHyphen"
        )

        XCTAssertEqual(markdown, "# AnnotationHyphen\n\nVor-Notiz-Nachsatz\n")
    }

    /// Der Fließtext des Masters wird unverändert als Markdown eingesetzt.
    /// Ohne Maskierung würde aus dem Absatz `# Kein Titel` eine Überschrift,
    /// ein manueller Umbruch bliebe weich und `text:s` fiele dem Trimmen zum
    /// Opfer.
    func testMasterParagraphsEscapeMarkdownAndKeepBreaksAndSpaces() throws {
        let markdown = try convertedMasterMarkdown(
            body: """
            <text:p># Kein Titel</text:p>
            <text:p>Erste Zeile<text:line-break/>Zweite Zeile</text:p>
            <text:p><text:s text:c="2"/>Eingerückter Anfang</text:p>
            <text:p>Ein *Stern* bleibt Text</text:p>
            """,
            name: "Escaped"
        )

        XCTAssertTrue(markdown.contains("\\# Kein Titel"), markdown)
        XCTAssertTrue(markdown.contains("Erste Zeile  \nZweite Zeile"), markdown)
        XCTAssertTrue(markdown.contains("  Eingerückter Anfang"), markdown)
        XCTAssertTrue(markdown.contains(#"Ein \*Stern\* bleibt Text"#), markdown)
    }

    func testMasterParagraphEscapesGFMStrikethroughAndEntitiesExactly() throws {
        let markdown = try convertedMasterMarkdown(
            body: "<text:p>~~kein Durchstreichen~~ &amp;copy;</text:p>",
            name: "GFMLiterals"
        )

        XCTAssertEqual(
            markdown,
            "# GFMLiterals\n\n" + #"\~\~kein Durchstreichen\~\~ \&copy;"# + "\n"
        )
    }

    func testEscapedGFMLiteralsSurviveAnIndependentPandocRender() throws {
        try requirePandoc()
        let markdown = try convertedMasterMarkdown(
            body: "<text:p>~~kein Durchstreichen~~ &amp;copy;</text:p>",
            name: "RenderedGFMLiterals"
        )
        let markdownURL = temporaryDirectory.appendingPathComponent("render-input.md")
        let plainURL = temporaryDirectory.appendingPathComponent("render-output.txt")
        try Data(markdown.utf8).write(to: markdownURL)
        let result = try ProcessRunner.run(
            executable: try PandocTool.resolve(nil),
            arguments: [
                "--from=gfm", "--to=plain", "--output", plainURL.path, markdownURL.path,
            ],
            currentDirectory: temporaryDirectory
        )

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertEqual(
            try String(contentsOf: plainURL, encoding: .utf8),
            "RenderedGFMLiterals\n\n~~kein Durchstreichen~~ &copy;\n"
        )
    }

    func testMasterParagraphKeepsCodeBlockIndentAsVisibleText() throws {
        let markdown = try convertedMasterMarkdown(
            body: """
            <text:p><text:s text:c="4"/>Vier</text:p>
            <text:p><text:tab/>Tab</text:p>
            """,
            name: "LeadingWhitespace"
        )

        XCTAssertEqual(
            markdown,
            "# LeadingWhitespace\n\n"
                + "&nbsp;&nbsp;&nbsp;&nbsp;Vier\n\n&nbsp;&nbsp;&nbsp;&nbsp;Tab\n"
        )
    }

    func testAssetRewriterChangesOnlyRealMarkdownLinkTargets() {
        let markdown = #"""
        ![real](images/image01.png)
        [angle](<images/image01.png> "title")
        `![inline](images/image01.png)`
        \[escaped](images/image01.png)
        ```text
        ![fenced](images/image01.png)
        ```
        ~~~text
        [tilde](images/image01.png)
        ~~~
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"""
            ![real](images/section01-image01.png)
            [angle](<images/section01-image01.png> "title")
            `![inline](images/image01.png)`
            \[escaped](images/image01.png)
            ```text
            ![fenced](images/image01.png)
            ```
            ~~~text
            [tilde](images/image01.png)
            ~~~
            """#
        )
    }

    func testAssetRewriterDoesNotTreatABacktickInFenceInfoAsAValidFence() {
        let markdown = #"""
        ``` info`bad
        [real](images/image01.png)
        ```
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"""
            ``` info`bad
            [real](images/section01-image01.png)
            ```
            """#
        )
    }

    func testAssetRewriterClosesMultiBacktickSpanAfterRawBackslash() {
        let markdown = #"``code\`` [bild](images/image01.png)"#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"``code\`` [bild](images/section01-image01.png)"#
        )
    }

    func testAssetRewriterTreatsUnclosedBacktickRunAsLiteral() {
        let markdown = #"`literal [bild](images/image01.png)"#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"`literal [bild](images/section01-image01.png)"#
        )
    }

    func testAssetRewriterDoesNotCloseCodeSpanAcrossParagraphs() {
        let markdown = #"""
        `literal

        [bild](images/image01.png)

        `later
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"""
            `literal

            [bild](images/section01-image01.png)

            `later
            """#
        )
    }

    func testAssetRewriterKeepsCodeSpanAcrossSoftLineBreak() {
        let markdown = #"""
        `code
        [inside](images/image01.png)` [outside](images/image01.png)
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"""
            `code
            [inside](images/image01.png)` [outside](images/section01-image01.png)
            """#
        )
    }

    func testAssetRewriterEndsUnclosedFenceWithBlockquote() {
        let markdown = #"""
        > ```
        > [inside](images/image01.png)
        [outside](images/image01.png)
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"""
            > ```
            > [inside](images/image01.png)
            [outside](images/section01-image01.png)
            """#
        )
    }

    func testAssetRewriterEndsUnclosedFenceWithListItem() {
        let markdown = #"""
        - ```
          [inside](images/image01.png)
        [outside](images/image01.png)
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"""
            - ```
              [inside](images/image01.png)
            [outside](images/section01-image01.png)
            """#
        )
    }

    /// Eingerückter Code darf Links nicht umschreiben. Ohne trennende Leerzeile
    /// ist derselbe Einzug laut GFM jedoch eine Absatzfortsetzung; deren echtes
    /// Linkziel muss weiterhin den neuen Asset-Namen erhalten.
    func testAssetRewriterDistinguishesIndentedCodeFromParagraphContinuations() {
        let markdown = #"""
        [real](images/image01.png)
            [root-continuation](images/image01.png)

            [root-code](images/image01.png)
        -     [list-code](images/image01.png)
        >     [quote-code](images/image01.png)
        > -     [quoted-list-code](images/image01.png)
        - item
            [list-continuation](images/image01.png)

              [list-continuation-code](images/image01.png)
        > - item
        >     [quoted-list-continuation](images/image01.png)
        >
        >       [quoted-list-continuation-code](images/image01.png)
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"""
            [real](images/section01-image01.png)
                [root-continuation](images/section01-image01.png)

                [root-code](images/image01.png)
            -     [list-code](images/image01.png)
            >     [quote-code](images/image01.png)
            > -     [quoted-list-code](images/image01.png)
            - item
                [list-continuation](images/section01-image01.png)

                  [list-continuation-code](images/image01.png)
            > - item
            >     [quoted-list-continuation](images/section01-image01.png)
            >
            >       [quoted-list-continuation-code](images/image01.png)
            """#
        )
    }

    func testAssetRewriterStartsIndentedCodeDirectlyAfterHeadingsInContainers() {
        let markdown = #"""
        # Root
            [root-code](images/image01.png)
        - # List
              [list-code](images/image01.png)
        > # Quote
        >     [quote-code](images/image01.png)
        Paragraph
            [continuation](images/image01.png)
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"""
            # Root
                [root-code](images/image01.png)
            - # List
                  [list-code](images/image01.png)
            > # Quote
            >     [quote-code](images/image01.png)
            Paragraph
                [continuation](images/section01-image01.png)
            """#
        )
    }

    func testAssetRewriterKeepsLazyBlockquoteParagraphContinuationOpen() {
        let markdown = #"""
        > Paragraph
            [continuation](images/image01.png)
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            #"""
            > Paragraph
                [continuation](images/section01-image01.png)
            """#
        )
    }

    func testAssetRewriterStartsIndentedCodeAfterSetextHeadingsInContainers() {
        let markdown = #"""
        Root
        ====
            [root-code](images/image01.png)
        - List
          ----
              [list-code](images/image01.png)
        > Quote
        > =====
        >     [quote-code](images/image01.png)
        """#

        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: markdown,
                from: "images/image01.png",
                to: "images/section01-image01.png"
            ),
            markdown
        )
    }

    func testAssetRewriterStartsIndentedCodeAfterThematicBreaks() {
        for marker in ["---", "***", "___"] {
            let markdown = "\(marker)\n    [code](images/image01.png)"
            XCTAssertEqual(
                MarkdownLinkTargetRewriter.replacing(
                    in: markdown,
                    from: "images/image01.png",
                    to: "images/section01-image01.png"
                ),
                markdown,
                marker
            )
        }
    }

    /// Ein Masterdokument ohne verlinkte Abschnitte braucht kein Pandoc: Es
    /// entsteht allein aus dem eigenen `content.xml`.
    private func convertedMasterMarkdown(body: String, name: String) throws -> String {
        let masterURL = temporaryDirectory.appendingPathComponent("\(name).odm")
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:xlink="http://www.w3.org/1999/xlink">
          <office:body><office:text>
        \(body)
          </office:text></office:body>
        </office:document-content>
        """
        try ZIPFixtureBuilder.odmPackage(contentXML: content).write(to: masterURL)

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: masterURL,
                destination: .directory(
                    temporaryDirectory.appendingPathComponent("\(name)-result")
                )
            )
        )
        return try String(contentsOf: result.markdownFile, encoding: .utf8)
    }

    private func masterContent(sections: [(String, String)]) -> String {
        let sectionXML = sections.map { name, reference in
            """
            <text:section text:name="\(name)">
              <text:section-source xlink:href="\(reference)" xlink:type="simple"/>
            </text:section>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:xlink="http://www.w3.org/1999/xlink">
          <office:body><office:text>
            <text:h text:outline-level="1">Master heading</text:h>
            <text:p>Master introduction.</text:p>
            \(sectionXML)
          </office:text></office:body>
        </office:document-content>
        """
    }

    private func wordFixture(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/WordProcessing")
            .appendingPathComponent(name)
    }

    private func requirePandoc() throws {
        do {
            _ = try PandocTool.resolve(nil)
        } catch {
            throw XCTSkip("Pandoc is required for ODM integration tests.")
        }
    }
}
