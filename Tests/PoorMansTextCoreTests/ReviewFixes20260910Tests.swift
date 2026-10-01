import Foundation
import XCTest
@testable import PoorMansTextCore

/// Regressionen für die Funde der CodeQA-Kampagne vom 2026-09-10.
final class ReviewFixes20260910Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextReviewFixes0910-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Frontmatter

    /// Ein Wagenrücklauf im Titel eines fremden Dokuments blieb unmaskiert, weil
    /// die Maskierung über `Character` lief und ein CRLF-Paar in Swift EIN
    /// `Character` ist, das weder auf `"\n"` noch auf `"\r"` passt. Ein solcher
    /// Titel konnte den YAML-Kopf schließen und eigenen Markdown-Inhalt
    /// anhängen.
    func testAControlCharacterInTheTitleCannotBreakOutOfTheFrontmatter() throws {
        for injected in ["Harmlos&#13;---&#13;# Eingeschleust", "Harmlos&#13;&#10;---&#13;&#10;# Eingeschleust"] {
            let sourceURL = root.appendingPathComponent("Tabelle-\(UUID().uuidString).ods")
            try ods(meta: "<dc:title>\(injected)</dc:title>").write(to: sourceURL)

            let result = try DocumentConverter().convert(
                ConversionRequest(
                    inputURL: sourceURL,
                    destination: .directory(root.appendingPathComponent(UUID().uuidString)),
                    options: ConversionOptions(frontmatter: true)
                )
            )
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

            // Genau zwei Kopfzeilen, und der eingeschleuste Text steht nicht
            // als eigene Überschrift im Dokument.
            let separators = markdown.components(separatedBy: "\n").filter { $0 == "---" }
            XCTAssertEqual(separators.count, 2, markdown)
            XCTAssertFalse(markdown.contains("\n# Eingeschleust"), markdown)
            XCTAssertFalse(markdown.contains("\r"), "Kein rohes CR in der Ausgabe")
            XCTAssertTrue(markdown.contains(#"title: "Harmlos\r"#), markdown)
        }
    }

    /// NUL und die Unicode-Zeilentrenner gehören ebenfalls nicht roh in die Datei.
    func testFurtherControlCharactersAreEscapedInTheFrontmatter() {
        let metadata = DocumentMetadata(title: "A\u{0000}B\u{2028}C\u{0085}D")
        XCTAssertEqual(
            metadata.frontmatter,
            "---\ntitle: \"A\\u0000B\\u2028C\\u0085D\"\n---\n"
        )
    }

    // MARK: - Paket-Metadaten

    /// Ein leeres `dc:creator` belegte den Schlüssel mit `""`. Der Rückfall auf
    /// `meta:initial-creator` kam dadurch nie zum Zug, und das Dokument nannte
    /// seinen Autor, ohne dass er im Frontmatter landete.
    func testAnEmptyCreatorDoesNotBlockTheInitialCreator() {
        let metadata = PackageMetadataParser.parse(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <office:meta><dc:creator/><meta:initial-creator>Autorin</meta:initial-creator></office:meta>
        </office:document-meta>
        """.utf8))
        XCTAssertEqual(metadata.author, "Autorin")
    }

    /// Dasselbe für Daten: Ein unlesbares `dcterms:created` darf den zweiten
    /// Schlüssel nicht verschlucken.
    func testAnUnreadableCreatedDateFallsBackToTheSecondKey() {
        let metadata = PackageMetadataParser.parse(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" \
        xmlns:dcterms="http://purl.org/dc/terms/">
        <office:meta><dcterms:created>irgendwann</dcterms:created>\
        <meta:creation-date>2026-07-25T08:16:58</meta:creation-date></office:meta>
        </office:document-meta>
        """.utf8))
        XCTAssertEqual(metadata.created.map(DocumentMetadata.iso8601), "2026-07-25T08:16:58Z")
    }

    /// `foundCharacters` meldet CDATA nicht; ohne eigenen Weg ging der Titel still verloren.
    func testACDATATitleIsRead() {
        let metadata = PackageMetadataParser.parse(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <cp:coreProperties \
        xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title><![CDATA[Bericht Q3]]></dc:title></cp:coreProperties>
        """.utf8))
        XCTAssertEqual(metadata.title, "Bericht Q3")
    }

    /// `Calendar` rechnet Unsinn still weiter, statt `nil` zu liefern:
    /// `\yr0\mo0\dy0` ergab den 30.11. des Jahres 2 im Frontmatter.
    func testAnImpossibleRTFCreationDateYieldsNoDate() {
        XCTAssertNil(RTFInfoParser.parse(Data(#"{\rtf1{\info{\creatim\yr0\mo0\dy0\hr0\min0}}}"#.utf8)).created)
        XCTAssertNil(RTFInfoParser.parse(Data(#"{\rtf1{\info{\creatim\yr2026\mo99\dy31\hr0\min0}}}"#.utf8)).created)
        XCTAssertEqual(
            RTFInfoParser.parse(Data(#"{\rtf1{\info{\creatim\yr2026\mo9\dy10\hr8\min5}}}"#.utf8))
                .created.map(DocumentMetadata.iso8601),
            "2026-09-10T08:05:00Z"
        )
    }

    // MARK: - Textbundle

    /// Assetnamen stehen im Markdown prozentkodiert, auf der Platte aber roh.
    /// Der Rewriter verglich nur wörtlich, verfehlte solche Links und das
    /// Textbundle verschob das Bild nach `assets/`, ohne den Link mitzunehmen —
    /// das Bild war still weg.
    func testTextbundleRewritesPercentEncodedAssetLinks() throws {
        let staged = root.appendingPathComponent("staged", isDirectory: true)
        let images = staged.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data("PNG".utf8).write(to: images.appendingPathComponent("image01.pn+g"))
        try Data("Text\n\n![Beispiel](images/image01.pn%2Bg)\n".utf8)
            .write(to: staged.appendingPathComponent("Seite.md"))

        let layout = try ConversionPostprocessor.applyTextbundleLayout(
            in: staged,
            markdownRelativePath: "Seite.md",
            assetRelativePaths: ["images/image01.pn+g"],
            fileManager: .default
        )

        XCTAssertEqual(layout.assets, ["assets/image01.pn+g"])
        let markdown = try String(contentsOf: staged.appendingPathComponent("text.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("![Beispiel](assets/image01.pn%2Bg)"), markdown)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staged.appendingPathComponent("assets/image01.pn+g").path)
        )
    }

    /// Ein roher Name bleibt roh — die Kodierung wird nur dort ergänzt, wo der
    /// gefundene Link selbst kodiert war.
    func testARawAssetLinkIsRewrittenWithoutEncoding() {
        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: "![x](images/bild a.png)", from: "images/bild a.png", to: "assets/bild a.png"
            ),
            "![x](images/bild a.png)"
        )
        XCTAssertEqual(
            MarkdownLinkTargetRewriter.replacing(
                in: "![x](<images/bild a.png>)", from: "images/bild a.png", to: "assets/bild a.png"
            ),
            "![x](<assets/bild a.png>)"
        )
    }

    /// Ein Ziel namens `*.textbundle` ohne Textbundle-Ablage ergab einen Ordner
    /// ohne `info.json` und `text.md`, den der Finder trotzdem für ein Paket hält.
    func testAnOutputNamedTextbundleNeedsTheTextbundleLayout() throws {
        let sourceURL = root.appendingPathComponent("Tabelle.ods")
        try ods(meta: "<dc:title>Titel</dc:title>").write(to: sourceURL)
        let target = root.appendingPathComponent("Notiz.textbundle", isDirectory: true)

        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(inputURL: sourceURL, destination: .directory(target))
            )
        ) { error in
            guard case ConversionError.invalidOutputName = error else {
                return XCTFail("unerwarteter Fehler: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // Mit der passenden Ablage entsteht das Bundle wie gehabt.
        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(target),
                options: ConversionOptions(outputLayout: .textbundle)
            )
        )
        XCTAssertEqual(result.markdownFile.lastPathComponent, "text.md")
    }

    // MARK: - Erkennung

    /// `inspect` und `detectFormat` banden keinen Ausführungskontext. Damit lief
    /// jeder Werkzeugstart der Erkennung ohne Zeitgrenze und ohne erreichbaren
    /// Abbruch-Token.
    func testInspectAndDetectFormatHonourACancellationToken() throws {
        let sourceURL = root.appendingPathComponent("Tabelle.ods")
        try ods(meta: "<dc:title>Titel</dc:title>").write(to: sourceURL)
        let token = ConversionCancellationToken()
        token.cancel()

        XCTAssertThrowsError(try DocumentConverter().inspect(sourceURL, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else {
                return XCTFail("unerwarteter Fehler: \(error)")
            }
        }
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: sourceURL, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else {
                return XCTFail("unerwarteter Fehler: \(error)")
            }
        }
        // Ohne Token bleibt die Erkennung unverändert erfolgreich.
        XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), .ods)
    }

    // MARK: - Hilfen

    private func ods(meta: String) throws -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
        <office:body><office:spreadsheet><table:table table:name="Blatt1">
        <table:table-row><table:table-cell office:value-type="string"><text:p>Wert</text:p></table:table-cell></table:table-row>
        </table:table></office:spreadsheet></office:body></office:document-content>
        """
        let metaXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <office:meta>\(meta)</office:meta>
        </office:document-meta>
        """
        return try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "mimetype",
                content: Data("application/vnd.oasis.opendocument.spreadsheet".utf8),
                isStored: true
            ),
            ZIPFixtureBuilder.Entry(name: "content.xml", content: Data(content.utf8)),
            ZIPFixtureBuilder.Entry(name: "meta.xml", content: Data(metaXML.utf8)),
        ])
    }
}
