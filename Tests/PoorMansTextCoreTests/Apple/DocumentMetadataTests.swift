import AppKit
import Foundation
import XCTest
@testable import PoorMansTextCore

/// Metadaten aus OOXML, OpenDocument, RTF und PDF sowie ihre Darstellung als
/// YAML-Frontmatter. Die Leser dürfen nie scheitern: Ein fehlender oder
/// kaputter Metadatenblock bedeutet „keine Angaben“, nicht „kein Dokument“.
final class DocumentMetadataTests: XCTestCase {
    func testOOXMLCorePropertiesAreRead() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title> Quartalsbericht: Q3 </dc:title><dc:creator>Daniel Müller</dc:creator>
        <dc:subject>Umsatz</dc:subject><dc:description>Entwurf</dc:description>
        <cp:keywords>bericht, umsatz; 2026</cp:keywords>
        <dcterms:created xsi:type="dcterms:W3CDTF">2026-07-25T08:16:58Z</dcterms:created>
        <dcterms:modified xsi:type="dcterms:W3CDTF">2026-08-01T10:00:00Z</dcterms:modified>
        </cp:coreProperties>
        """
        let metadata = PackageMetadataParser.parse(Data(xml.utf8))

        XCTAssertEqual(metadata.title, "Quartalsbericht: Q3")
        XCTAssertEqual(metadata.author, "Daniel Müller")
        XCTAssertEqual(metadata.subject, "Umsatz")
        XCTAssertEqual(metadata.description, "Entwurf")
        XCTAssertEqual(metadata.keywords, ["bericht", "umsatz", "2026"])
        XCTAssertEqual(metadata.created.map(DocumentMetadata.iso8601), "2026-07-25T08:16:58Z")
        XCTAssertEqual(metadata.modified.map(DocumentMetadata.iso8601), "2026-08-01T10:00:00Z")
    }

    func testOpenDocumentMetaPrefersTheInitialCreatorAndReadsZonelessDatesAsUTC() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <office:meta><dc:title>Kapitel 1</dc:title><meta:initial-creator>Autorin</meta:initial-creator>
        <dc:creator>Letzte Bearbeiterin</dc:creator><meta:keyword>eins</meta:keyword><meta:keyword>zwei</meta:keyword>
        <meta:creation-date>2026-07-25T08:16:58</meta:creation-date><dc:date>2026-07-26T09:00:00.123456</dc:date>
        </office:meta></office:document-meta>
        """
        let metadata = PackageMetadataParser.parse(Data(xml.utf8))

        XCTAssertEqual(metadata.title, "Kapitel 1")
        XCTAssertEqual(metadata.author, "Letzte Bearbeiterin")
        XCTAssertEqual(metadata.keywords, ["eins", "zwei"])
        XCTAssertEqual(metadata.created.map(DocumentMetadata.iso8601), "2026-07-25T08:16:58Z")
        XCTAssertEqual(metadata.modified.map(DocumentMetadata.iso8601), "2026-07-26T09:00:00Z")
    }

    func testEmptyFieldsAndBrokenXMLYieldNoMetadata() {
        let empty = """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title></dc:title><dc:creator>  </dc:creator></cp:coreProperties>
        """
        XCTAssertTrue(PackageMetadataParser.parse(Data(empty.utf8)).isEmpty)
        XCTAssertTrue(PackageMetadataParser.parse(Data("<broken".utf8)).isEmpty)
        XCTAssertNil(DocumentMetadata().frontmatter)
    }

    func testRTFInfoGroupIsReadWithEscapesAndNestedGroups() {
        let rtf = #"""
        {\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}
        {\info{\title Bericht \'fcber {\b Q3}}{\author J\u246?rg \{Test\}}{\subject Umsatz}{\keywords a; b}
        {\doccomm Kommentar}{\creatim\yr2026\mo9\dy2\hr10\min5}{\revtim\yr2026\mo9\dy3}}
        \pard Text\par}
        """#
        let metadata = RTFInfoParser.parse(Data(rtf.utf8))

        XCTAssertEqual(metadata.title, "Bericht über Q3")
        XCTAssertEqual(metadata.author, "Jörg {Test}")
        XCTAssertEqual(metadata.subject, "Umsatz")
        XCTAssertEqual(metadata.keywords, ["a", "b"])
        XCTAssertEqual(metadata.description, "Kommentar")
        XCTAssertEqual(metadata.created.map(DocumentMetadata.iso8601), "2026-09-02T10:05:00Z")
        XCTAssertEqual(metadata.modified.map(DocumentMetadata.iso8601), "2026-09-03T00:00:00Z")
    }

    func testRTFWithoutInfoGroupOrWithInfoOnlyInTextYieldsNothing() {
        XCTAssertTrue(RTFInfoParser.parse(Data(#"{\rtf1\ansi Nur Text \information}"#.utf8)).isEmpty)
        XCTAssertTrue(RTFInfoParser.parse(Data("not rtf".utf8)).isEmpty)
    }

    func testFrontmatterQuotesEveryValueAndOmitsMissingFields() {
        let metadata = DocumentMetadata(
            title: "Bericht: \"Q3\" \\ Ende",
            keywords: ["a", "b c"],
            created: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(
            metadata.frontmatter,
            """
            ---
            title: "Bericht: \\"Q3\\" \\\\ Ende"
            keywords: ["a", "b c"]
            created: 2027-01-15T08:00:00Z
            ---

            """
        )
        XCTAssertEqual(Set(metadata.jsonFields.keys), ["title", "keywords", "created"])
    }

    func testAnODSWithMetaXMLGetsFrontmatterThroughTheNormalConversion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Tabelle.ods")
        try odsWithMetadata(title: "Umsatz 2026", author: "Buchhaltung").write(to: sourceURL)

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                options: ConversionOptions(frontmatter: true)
            )
        )

        XCTAssertEqual(result.metadata.title, "Umsatz 2026")
        XCTAssertEqual(result.metadata.author, "Buchhaltung")
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(
            markdown.hasPrefix("---\ntitle: \"Umsatz 2026\"\nauthor: \"Buchhaltung\"\n---\n# "),
            markdown
        )
        XCTAssertFalse(result.diagnostics.contains(.metadataUnavailable))

        // Ohne Option bleibt die Ausgabe unverändert, die Angaben sind trotzdem da.
        let plain = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(directory.appendingPathComponent("plain"))
            )
        )
        XCTAssertEqual(plain.metadata.title, "Umsatz 2026")
        XCTAssertTrue(try String(contentsOf: plain.markdownFile, encoding: .utf8).hasPrefix("# "))
    }

    func testASourceWithoutMetadataGetsAWarningInsteadOfAnEmptyHeader() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Foto.png")
        try FileManager.default.copyItem(
            at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"),
            to: sourceURL
        )

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                options: ConversionOptions(imageTextRecognition: .disabled, frontmatter: true)
            )
        )

        XCTAssertTrue(result.diagnostics.contains(.metadataUnavailable))
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).hasPrefix("# "))
    }

    func testPDFInformationDictionaryIsRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Info.pdf")
        try createPDF(
            text: "Ein PDF mit Titel und Autor im Info-Wörterbuch.",
            at: sourceURL,
            title: "Handbuch",
            author: "Redaktion"
        )

        let result = try DocumentConverter().convert(
            ConversionRequest(inputURL: sourceURL, options: ConversionOptions(frontmatter: true))
        )

        XCTAssertEqual(result.metadata.title, "Handbuch")
        XCTAssertEqual(result.metadata.author, "Redaktion")
        XCTAssertNotNil(result.metadata.created)
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).hasPrefix("---\ntitle: \"Handbuch\""))
    }

    func testTextbundleLayoutRenamesAssetsAndRewritesTheLinks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Foto.png")
        try FileManager.default.copyItem(
            at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"),
            to: sourceURL
        )

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                options: ConversionOptions(imageTextRecognition: .disabled, outputLayout: .textbundle)
            )
        )

        XCTAssertEqual(result.outputDirectory.lastPathComponent, "Foto.textbundle")
        XCTAssertEqual(result.markdownFile.lastPathComponent, "text.md")
        XCTAssertEqual(
            result.assets.map { $0.path.replacingOccurrences(of: result.outputDirectory.path + "/", with: "") },
            ["assets/image01.png"]
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("](assets/image01.png)"), markdown)
        XCTAssertFalse(markdown.contains("images/"), markdown)
        let info = try JSONSerialization.jsonObject(
            with: Data(contentsOf: result.outputDirectory.appendingPathComponent("info.json"))
        ) as? [String: Any]
        XCTAssertEqual(info?["version"] as? Int, 2)
        XCTAssertEqual(info?["type"] as? String, "net.daringfireball.markdown")
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: result.outputDirectory.path)),
            ["assets", "info.json", "text.md"]
        )

        // Ein zweiter Ordnerlauf darf das Bundle nicht als Bilderquelle ansehen.
        XCTAssertEqual(try InputEnumerator().enumerate([directory]).map(\.url), [sourceURL])

        // Ein frei gewähltes Ziel muss die Endung tragen.
        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(
                    inputURL: sourceURL,
                    destination: .directory(directory.appendingPathComponent("Ohne Endung")),
                    options: ConversionOptions(imageTextRecognition: .disabled, outputLayout: .textbundle)
                )
            )
        ) { error in
            guard case ConversionError.invalidOutputName = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDOCXCorePropertiesReachTheResultThroughThePandocAdapter() throws {
        try XCTSkipUnless(
            ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]
                .contains(where: FileManager.default.isExecutableFile),
            "Pandoc is required for the DOCX metadata test."
        )
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Bericht.docx")
        let core = """
        <?xml version="1.0" encoding="UTF-8"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Bericht</dc:title><dc:creator>Team</dc:creator></cp:coreProperties>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>Fixture text</w:t></w:r></w:p></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Override PartName="/word/document.xml" ContentType="\(ZIPFixtureBuilder.docxMainContentType)"/>
        </Types>
        """
        // Pandoc findet den Hauptteil nur über die Paketbeziehungen.
        let packageRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        </Relationships>
        """
        try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(name: "[Content_Types].xml", content: Data(contentTypes.utf8)),
            ZIPFixtureBuilder.Entry(name: "_rels/.rels", content: Data(packageRelationships.utf8)),
            ZIPFixtureBuilder.Entry(name: "word/document.xml", content: Data(document.utf8)),
            ZIPFixtureBuilder.Entry(name: "docProps/core.xml", content: Data(core.utf8)),
        ]).write(to: sourceURL)

        let result = try DocumentConverter().convert(
            ConversionRequest(inputURL: sourceURL, options: ConversionOptions(frontmatter: true))
        )

        XCTAssertEqual(result.metadata.title, "Bericht")
        XCTAssertEqual(result.metadata.author, "Team")
        XCTAssertTrue(
            try String(contentsOf: result.markdownFile, encoding: .utf8)
                .hasPrefix("---\ntitle: \"Bericht\"\nauthor: \"Team\"\n---\n")
        )
    }

    // MARK: - Helfer

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextMetadataTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func odsWithMetadata(title: String, author: String) throws -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
        <office:body><office:spreadsheet><table:table table:name="Blatt1">
        <table:table-row><table:table-cell office:value-type="string"><text:p>Wert</text:p></table:table-cell></table:table-row>
        </table:table></office:spreadsheet></office:body></office:document-content>
        """
        let meta = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <office:meta><dc:title>\(title)</dc:title><meta:initial-creator>\(author)</meta:initial-creator></office:meta>
        </office:document-meta>
        """
        return try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "mimetype",
                content: Data("application/vnd.oasis.opendocument.spreadsheet".utf8),
                isStored: true
            ),
            ZIPFixtureBuilder.Entry(name: "content.xml", content: Data(content.utf8)),
            ZIPFixtureBuilder.Entry(name: "meta.xml", content: Data(meta.utf8)),
        ])
    }

    private func createPDF(text: String, at url: URL, title: String, author: String) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw NSError(domain: "DocumentMetadataTests", code: 1)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextAuthor: author]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw NSError(domain: "DocumentMetadataTests", code: 2)
        }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            .draw(at: CGPoint(x: 72, y: 720))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }
}
