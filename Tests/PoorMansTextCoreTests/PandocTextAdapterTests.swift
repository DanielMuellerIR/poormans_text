import AppKit
import Foundation
import XCTest
@testable import PoorMansTextCore

/// HTML, Webarchive, EPUB und die Pandoc-Textformate. Alle brauchen Pandoc;
/// ohne Pandoc werden die Umwandlungen übersprungen, die Erkennung nicht.
final class PandocTextAdapterTests: XCTestCase {
    private var root: URL!
    private static let pandocAvailable = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]
        .contains(where: FileManager.default.isExecutableFile)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextPandocTextTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - HTML

    func testHTMLKeepsLocalImagesTurnsRemoteImagesIntoLinksAndExtractsEmbeddedOnes() throws {
        try requirePandoc()
        let pngData = try pngFixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bilder"), withIntermediateDirectories: true)
        try pngData.write(to: root.appendingPathComponent("bilder/lokal.png"))
        let outside = root.deletingLastPathComponent().appendingPathComponent("PoorMansTextOutside-\(UUID().uuidString).png")
        try pngData.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Seite &amp; Titel</title>
        <meta name="author" content="Redaktion"></head>
        <body><h1>Überschrift</h1>
        <p>Lokal: <img src="bilder/lokal.png" alt="Lokales Bild"></p>
        <p>Entfernt: <img src="https://example.com/remote.png" alt="Entferntes Bild"></p>
        <p>Eingebettet: <img src="data:image/png;base64,\(pngData.base64EncodedString())" alt="Eingebettet"></p>
        <p>Fehlt: <img src="bilder/fehlt.png" alt="Fehlendes Bild"></p>
        <p>Außerhalb: <img src="../\(outside.lastPathComponent)" alt="Außerhalb"></p>
        <script>alert("nein")</script>
        </body></html>
        """
        let sourceURL = root.appendingPathComponent("Seite.html")
        try Data(html.utf8).write(to: sourceURL)

        let result = try DocumentConverter().convert(
            ConversionRequest(inputURL: sourceURL, options: ConversionOptions(frontmatter: true))
        )

        XCTAssertEqual(result.format, .html)
        XCTAssertEqual(result.assets.map(\.lastPathComponent), ["image01.png", "image02.png"])
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\ntitle: \"Seite & Titel\"\nauthor: \"Redaktion\"\n---\n"), markdown)
        XCTAssertTrue(markdown.contains("![Lokales Bild](images/image01.png)"), markdown)
        XCTAssertTrue(markdown.contains("![Eingebettet](images/image02.png)"), markdown)
        XCTAssertTrue(markdown.contains("[Entferntes Bild](https://example.com/remote.png)"), markdown)
        XCTAssertFalse(markdown.contains("remote.png)") && markdown.contains("![Entferntes"), markdown)
        XCTAssertTrue(markdown.contains("Fehlendes Bild"), markdown)
        XCTAssertFalse(markdown.contains("fehlt.png"), markdown)
        XCTAssertFalse(markdown.contains(outside.lastPathComponent), markdown)
        XCTAssertFalse(markdown.contains("alert"), markdown)
        XCTAssertTrue(result.diagnostics.contains(.htmlStructureSimplified))
        XCTAssertTrue(result.diagnostics.contains(.remoteImagesKeptAsLinks(1)))
        XCTAssertTrue(result.diagnostics.contains(.missingImagesDropped(2)), result.warnings.joined(separator: "\n"))
    }

    func testHTMLIsDetectedByContentWithoutAnExtension() throws {
        let sourceURL = root.appendingPathComponent("seite")
        try Data("<html><body><p>Hallo</p></body></html>".utf8).write(to: sourceURL)
        XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), .html)

        let plain = root.appendingPathComponent("notiz")
        try Data("nur text".utf8).write(to: plain)
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: plain))
    }

    // MARK: - Webarchive

    func testWebArchiveUsesItsOwnSubresourcesForImages() throws {
        try requirePandoc()
        let pngData = try pngFixture()
        let html = """
        <html><head><title>Archiv</title></head><body>
        <p><img src="https://example.com/a.png" alt="Aus dem Archiv"></p>
        <p><img src="/pfad/b.png" alt="Relativ"></p>
        <p><img src="https://example.com/c.png" alt="Nicht enthalten"></p>
        </body></html>
        """
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(html.utf8),
                "WebResourceMIMEType": "text/html",
                "WebResourceURL": "https://example.com/seite.html",
                "WebResourceTextEncodingName": "UTF-8",
            ],
            "WebSubresources": [
                ["WebResourceData": pngData, "WebResourceMIMEType": "image/png", "WebResourceURL": "https://example.com/a.png"],
                ["WebResourceData": pngData, "WebResourceMIMEType": "image/png", "WebResourceURL": "https://example.com/pfad/b.png"],
                ["WebResourceData": Data("body{}".utf8), "WebResourceMIMEType": "text/css", "WebResourceURL": "https://example.com/s.css"],
            ],
        ]
        let sourceURL = root.appendingPathComponent("Seite.webarchive")
        try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0).write(to: sourceURL)

        XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), .webarchive)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))

        XCTAssertEqual(result.assets.count, 2)
        XCTAssertEqual(result.metadata.title, "Archiv")
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("![Aus dem Archiv](images/image01.png)"), markdown)
        XCTAssertTrue(markdown.contains("![Relativ](images/image02.png)"), markdown)
        XCTAssertTrue(markdown.contains("[Nicht enthalten](https://example.com/c.png)"), markdown)
    }

    func testABrokenWebArchiveIsRejectedAsInvalidInput() throws {
        let sourceURL = root.appendingPathComponent("Kaputt.webarchive")
        try Data("bplist00 not really".utf8).write(to: sourceURL)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))) { error in
            guard case ConversionError.invalidInput(_, let format, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(format, .webarchive)
        }
    }

    // MARK: - Textformate

    func testOrgLaTeXMediaWikiTextileAndRSTConvertThroughPandoc() throws {
        try requirePandoc()
        let cases: [(name: String, content: String, format: InputFormat, expected: String)] = [
            ("Notizen.org", "* Überschrift\n\nText mit *fett*.\n", .org, "# Überschrift"),
            ("Arbeit.tex", "\\documentclass{article}\\begin{document}\\section{Einleitung}Text mit \\textbf{fett}.\\end{document}", .latex, "# Einleitung"),
            ("Seite.wiki", "== Abschnitt ==\n\nText mit '''fett'''.\n", .mediawiki, "## Abschnitt"),
            ("Eintrag.textile", "h1. Titel\n\nText mit *fett*.\n", .textile, "# Titel"),
            ("Doku.rst", "Titel\n=====\n\nText mit **fett**.\n", .rst, "# Titel"),
        ]
        for testCase in cases {
            let sourceURL = root.appendingPathComponent(testCase.name)
            try Data(testCase.content.utf8).write(to: sourceURL)
            XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), testCase.format, testCase.name)

            let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))

            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertTrue(markdown.contains(testCase.expected), "\(testCase.name): \(markdown)")
            XCTAssertTrue(markdown.contains("**fett**"), "\(testCase.name): \(markdown)")
        }
    }

    func testOrgFilesTakeImagesFromNextToTheSource() throws {
        try requirePandoc()
        try pngFixture().write(to: root.appendingPathComponent("grafik.png"))
        let sourceURL = root.appendingPathComponent("Bericht.org")
        try Data("* Bild\n\n[[file:grafik.png]]\n".utf8).write(to: sourceURL)

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))

        XCTAssertEqual(result.assets.map(\.lastPathComponent), ["image01.png"])
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("images/image01.png"))
    }

    func testLaTeXCannotReadOtherFilesThroughInput() throws {
        try requirePandoc()
        let secret = root.appendingPathComponent("geheim.tex")
        try Data("GEHEIMER INHALT".utf8).write(to: secret)
        let sourceURL = root.appendingPathComponent("Angriff.tex")
        try Data("\\documentclass{article}\\begin{document}Sichtbar \\input{geheim.tex}\\end{document}".utf8).write(to: sourceURL)

        let markdown: String
        do {
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))
            markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        } catch {
            // Pandoc darf den Lauf auch abbrechen; nur der Inhalt darf nicht durch.
            return
        }
        XCTAssertFalse(markdown.contains("GEHEIMER INHALT"), markdown)
    }

    func testTextFormatsRequireTheirExtensionAndBinaryContentIsRejected() throws {
        let noExtension = root.appendingPathComponent("notizen")
        try Data("* Überschrift\n".utf8).write(to: noExtension)
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: noExtension))

        let binary = root.appendingPathComponent("Bild.org")
        try Data([0x00, 0x01, 0x02]).write(to: binary)
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: binary)) { error in
            guard case ConversionError.invalidInput(_, let format, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(format, .org)
        }

        // Nur eine XML-Datei mit DocBook-Namensraum ist ein DocBook.
        let docbook = root.appendingPathComponent("buch.xml")
        try Data("<?xml version=\"1.0\"?><book xmlns=\"http://docbook.org/ns/docbook\"><title>T</title></book>".utf8).write(to: docbook)
        XCTAssertEqual(try DocumentConverter().detectFormat(at: docbook), .docbook)
        let otherXML = root.appendingPathComponent("daten.xml")
        try Data("<?xml version=\"1.0\"?><daten><wert>1</wert></daten>".utf8).write(to: otherXML)
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: otherXML))
    }

    // MARK: - EPUB und FB2

    func testEPUBIsFlattenedWithItsImages() throws {
        try requirePandoc()
        let pngData = try pngFixture()
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">x</dc:identifier>
        <dc:title>Testbuch</dc:title><dc:creator>Anna Autorin</dc:creator><dc:date>2020-05-01</dc:date>
        <dc:language>de</dc:language></metadata>
        <manifest>
        <item id="k1" href="kapitel1.xhtml" media-type="application/xhtml+xml"/>
        <item id="k2" href="kapitel2.xhtml" media-type="application/xhtml+xml"/>
        <item id="b1" href="bild.png" media-type="image/png"/>
        </manifest>
        <spine><itemref idref="k1"/><itemref idref="k2"/></spine>
        </package>
        """
        let chapter1 = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><h1>Kapitel eins</h1><p>Erster Text.</p></body></html>"
        let chapter2 = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><h1>Kapitel zwei</h1><p><img src=\"bild.png\" alt=\"Bild\"/></p></body></html>"
        let epub = try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(name: "mimetype", content: Data("application/epub+zip".utf8), isStored: true),
            ZIPFixtureBuilder.Entry(name: "META-INF/container.xml", content: Data(container.utf8)),
            ZIPFixtureBuilder.Entry(name: "OEBPS/content.opf", content: Data(opf.utf8)),
            ZIPFixtureBuilder.Entry(name: "OEBPS/kapitel1.xhtml", content: Data(chapter1.utf8)),
            ZIPFixtureBuilder.Entry(name: "OEBPS/kapitel2.xhtml", content: Data(chapter2.utf8)),
            ZIPFixtureBuilder.Entry(name: "OEBPS/bild.png", content: pngData),
        ])
        let sourceURL = root.appendingPathComponent("Buch.epub")
        try epub.write(to: sourceURL)

        XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), .epub)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))

        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Kapitel eins"), markdown)
        XCTAssertTrue(markdown.contains("Kapitel zwei"), markdown)
        XCTAssertEqual(result.assets.map(\.lastPathComponent), ["image01.png"])
        XCTAssertTrue(markdown.contains("images/image01.png"), markdown)
        XCTAssertTrue(result.diagnostics.contains(.epubFlattened))
        // Die Metadaten kommen aus dem OPF; vorher blieb `--frontmatter` leer.
        XCTAssertEqual(result.metadata.title, "Testbuch")
        XCTAssertEqual(result.metadata.author, "Anna Autorin")
        XCTAssertEqual(result.metadata.created, DocumentMetadata.parseDate("2020-05-01"))
        XCTAssertNil(result.metadata.modified)
    }

    /// Der OPF-Leser ohne Pandoc: `container.xml` nennt den Pfad, auch mit
    /// führendem Schrägstrich; Dublin Core wird wie in `meta.xml` gelesen.
    func testEPUBMetadataAreReadFromTheOPF() throws {
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="/Inhalt/buch.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Buchtitel</dc:title><dc:creator>Erste Autorin</dc:creator><dc:creator>Zweiter Autor</dc:creator>
        <dc:description>Kurzbeschreibung</dc:description><dc:subject>Thema</dc:subject><dc:date>2019-12-24</dc:date>
        </metadata><manifest/><spine/></package>
        """
        let epub = try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(name: "mimetype", content: Data("application/epub+zip".utf8), isStored: true),
            ZIPFixtureBuilder.Entry(name: "META-INF/container.xml", content: Data(container.utf8)),
            ZIPFixtureBuilder.Entry(name: "Inhalt/buch.opf", content: Data(opf.utf8)),
        ])
        let sourceURL = root.appendingPathComponent("Meta.epub")
        try epub.write(to: sourceURL)

        let metadata = EPUBMetadataReader.read(fromPackageAt: sourceURL)
        XCTAssertEqual(metadata.title, "Buchtitel")
        XCTAssertEqual(metadata.author, "Erste Autorin")
        XCTAssertEqual(metadata.description, "Kurzbeschreibung")
        XCTAssertEqual(metadata.subject, "Thema")
        XCTAssertEqual(metadata.created, DocumentMetadata.parseDate("2019-12-24"))
        XCTAssertNil(metadata.modified)

        // Ohne container.xml gibt es keine Angaben, aber auch keinen Fehler.
        let bare = try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(name: "mimetype", content: Data("application/epub+zip".utf8), isStored: true),
        ])
        let bareURL = root.appendingPathComponent("Leer.epub")
        try bare.write(to: bareURL)
        XCTAssertTrue(EPUBMetadataReader.read(fromPackageAt: bareURL).isEmpty)
    }

    func testAZIPWithoutEPUBMimetypeIsNotAnEPUB() throws {
        let zip = try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(name: "readme.txt", content: Data("x".utf8)),
        ])
        let sourceURL = root.appendingPathComponent("Nicht.epub")
        try zip.write(to: sourceURL)
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: sourceURL)) { error in
            guard case ConversionError.invalidInput(_, let format, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(format, .epub)
        }
    }

    func testFB2ConvertsItsSectionsAndEmbeddedBinaries() throws {
        try requirePandoc()
        let pngData = try pngFixture()
        let fb2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
        <description><title-info><book-title>Geschichte</book-title>
        <author><first-name>Anna</first-name><last-name>Autorin</last-name></author></title-info></description>
        <body><section><title><p>Erstes Kapitel</p></title><p>Ein <strong>starker</strong> Satz.</p>
        <image l:href="#bild.png"/></section></body>
        <binary id="bild.png" content-type="image/png">\(pngData.base64EncodedString())</binary>
        </FictionBook>
        """
        let sourceURL = root.appendingPathComponent("Buch.fb2")
        try Data(fb2.utf8).write(to: sourceURL)

        XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), .fb2)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))

        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Erstes Kapitel"), markdown)
        XCTAssertTrue(markdown.contains("**starker**"), markdown)
        XCTAssertEqual(result.assets.count, 1, markdown)
        XCTAssertEqual(result.metadata.title, "Geschichte")
        XCTAssertEqual(result.metadata.author, "Anna Autorin")
    }

    /// Der FB2-Leser ohne Pandoc: nur `title-info` zählt, der erste Autor,
    /// Genres als Schlüsselwörter, Annotation als Beschreibung, das Datum
    /// bevorzugt aus `value`.
    func testFB2MetadataComeFromTheTitleInfoOnly() throws {
        let fb2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
        <description>
        <title-info><genre>prose</genre><genre>history</genre>
        <author><first-name>Anna</first-name><middle-name>B.</middle-name><last-name>Autorin</last-name></author>
        <author><first-name>Zweiter</first-name><last-name>Autor</last-name></author>
        <book-title>Die Geschichte</book-title>
        <annotation><p>Erster Absatz.</p><p>Zweiter Absatz.</p></annotation>
        <date value="2005-01-31">31. Januar 2005</date></title-info>
        <document-info><author><nickname>scanner42</nickname></author><date>2010-01-01</date></document-info>
        </description>
        <body><section><p>Text</p></section></body>
        </FictionBook>
        """
        let metadata = FB2MetadataParser.parse(Data(fb2.utf8))

        XCTAssertEqual(metadata.title, "Die Geschichte")
        XCTAssertEqual(metadata.author, "Anna B. Autorin")
        XCTAssertEqual(metadata.keywords, ["prose", "history"])
        XCTAssertEqual(metadata.description, "Erster Absatz. Zweiter Absatz.")
        XCTAssertEqual(metadata.created, DocumentMetadata.parseDate("2005-01-31"))

        let nickname = """
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>
        <author><nickname>anon</nickname></author><book-title>T</book-title><date>2001-02-03</date>
        </title-info></description></FictionBook>
        """
        let byNickname = FB2MetadataParser.parse(Data(nickname.utf8))
        XCTAssertEqual(byNickname.author, "anon")
        XCTAssertEqual(byNickname.created, DocumentMetadata.parseDate("2001-02-03"))
    }

    func testTheFormatCatalogNamesPandocForEveryTextFormat() {
        let catalog = DocumentConverter().formatCatalog(
            resolver: ExternalToolResolver(pandocExecutable: URL(fileURLWithPath: "/nonexistent/pandoc"))
        )
        for format in [InputFormat.html, .webarchive, .epub, .latex, .docbook, .org, .mediawiki, .textile, .rst, .fb2] {
            let entry = catalog.first { $0.format.format == format }
            XCTAssertEqual(entry?.format.requiredTools, [.pandoc], format.rawValue)
            XCTAssertEqual(entry?.isAvailable, false, format.rawValue)
        }
    }

    // MARK: - Helfer

    // MARK: - Zeichensatz, große Bilder, Webarchiv-Dedup (Roadmap-Punkte 2026-09-10)

    /// Der Rückfall ging von UTF-8 direkt auf Windows-1252; eine Seite in
    /// windows-1251 wurde vollständig Mojibake, mit der allgemeinen
    /// Kodierungswarnung statt dem deklarierten Zeichensatz.
    func testHTMLDeclaredCharsetIsHonoredBeforeAssumingWindows1252() throws {
        try requirePandoc()
        let cyrillic = try XCTUnwrap(
            "<html><head><meta charset=\"windows-1251\"><title>Тест</title></head><body><p>Привет, мир</p></body></html>"
                .data(using: .windowsCP1251)
        )
        let declared = root.appendingPathComponent("kyrillisch.html")
        try cyrillic.write(to: declared)

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: declared))
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("Привет, мир"))
        XCTAssertEqual(result.metadata.title, "Тест")
        XCTAssertFalse(result.diagnostics.contains(.textEncodingAssumed), result.warnings.joined(separator: "\n"))

        // Ohne Deklaration bleibt es bei der Annahme samt Warnung.
        let undeclared = root.appendingPathComponent("latin.html")
        try XCTUnwrap("<html><body><p>Grüße</p></body></html>".data(using: .windowsCP1252)).write(to: undeclared)
        let assumed = try DocumentConverter().convert(ConversionRequest(inputURL: undeclared))
        XCTAssertTrue(try String(contentsOf: assumed.markdownFile, encoding: .utf8).contains("Grüße"))
        XCTAssertTrue(assumed.diagnostics.contains(.textEncodingAssumed))

        // Die drei Schreibweisen der Deklaration.
        XCTAssertEqual(PandocTextAdapter.declaredCharset(in: Data("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=Shift_JIS\">".utf8)), "Shift_JIS")
        XCTAssertEqual(PandocTextAdapter.declaredCharset(in: Data("<?xml version=\"1.0\" encoding=\"ISO-8859-2\"?><html/>".utf8)), "ISO-8859-2")
        XCTAssertNil(PandocTextAdapter.declaredCharset(in: Data("<html><body>nichts</body></html>".utf8)))
    }

    /// Ein zu großes Einzelbild neben der Quelle endete als Dateisystemfehler
    /// für die gesamte Umwandlung, statt wie andere unbrauchbare Verweise nur
    /// wegzufallen. Die Datei ist spärlich: Größe ohne Platzverbrauch.
    func testAnOversizedLocalImageIsDroppedInsteadOfAbortingTheDocument() throws {
        try Self.pngBytes.write(to: root.appendingPathComponent("klein.png"))
        let huge = root.appendingPathComponent("riesig.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(HTMLImageSourceResolver.maximumLocalImageBytes) + 1)
        try handle.close()

        let resolution = try resolveImages(
            "<p><img src=\"riesig.png\" alt=\"Riesig\"><img src=\"klein.png\" alt=\"Klein\"></p>",
            baseDirectory: root
        )

        XCTAssertEqual(resolution.missingImagesDropped, 1)
        XCTAssertTrue(resolution.html.contains("Riesig"), resolution.html)
        XCTAssertTrue(resolution.html.contains("src=\"external/local02.png\""), resolution.html)
    }

    /// Eine 200-mal verwendete Nebenressource eines Webarchivs wurde 200-mal
    /// geschrieben; die Dedup-Tabelle galt nur für Dateien neben der Quelle.
    func testAWebArchiveSubresourceUsedTwiceIsWrittenOnce() throws {
        let subresources = [
            "https://example.com/spacer.png": HTMLImageSourceResolver.Subresource(data: Self.pngBytes, mimeType: "image/png"),
        ]
        let resolution = try resolveImages(
            "<img src=\"https://example.com/spacer.png\" alt=\"a\"><img src=\"https://example.com/spacer.png\" alt=\"b\">",
            subresources: subresources
        )

        XCTAssertEqual(resolution.html.components(separatedBy: "src=\"external/resource01.png\"").count - 1, 2, resolution.html)
        XCTAssertFalse(resolution.html.contains("resource02"), resolution.html)
        XCTAssertEqual(resolution.missingImagesDropped, 0)
    }

    private func requirePandoc() throws {
        try XCTSkipUnless(Self.pandocAvailable, "Pandoc is required for this conversion test.")
    }

    private func pngFixture() throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
    }
    // MARK: - Bildverweise in fremdem HTML (Review-Funde 2026-09-10)

    private static let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    private func resolveImages(
        _ html: String,
        baseDirectory: URL? = nil,
        subresources: [String: HTMLImageSourceResolver.Subresource] = [:]
    ) throws -> HTMLImageSourceResolver.Resolution {
        let work = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return try HTMLImageSourceResolver.resolve(
            html: html, baseDirectory: baseDirectory, baseURL: nil,
            subresources: subresources, workDirectory: work
        )
    }

    /// Die Endung stammte aus dem fremden Verweis, nicht aus dem geprüften Typ.
    /// Ein `<img src="seite.html">` landete dadurch als `images/image01.html`
    /// im Ergebnisordner und wurde im Markdown verlinkt — geöffnet lud diese
    /// Datei genau die entfernten Ressourcen nach, die der Kern nie lädt.
    func testAReferencedNonImageFileIsNotCopiedIntoTheResult() throws {
        let source = root.appendingPathComponent("quelle", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("<html><img src=\"http://example.test/t.png\"></html>".utf8)
            .write(to: source.appendingPathComponent("nachlader.html"))
        try Self.pngBytes.write(to: source.appendingPathComponent("echt.png"))

        let resolution = try resolveImages(
            "<img src=\"nachlader.html\" alt=\"A\"><img src=\"echt.png\" alt=\"B\">",
            baseDirectory: source
        )

        XCTAssertFalse(resolution.html.contains("nachlader"), resolution.html)
        XCTAssertFalse(resolution.html.contains(".html\""), resolution.html)
        XCTAssertTrue(resolution.html.contains("external/local02.png"), resolution.html)
        XCTAssertEqual(resolution.missingImagesDropped, 1)
    }

    /// Dasselbe für eine Nebenressource eines Webarchivs: Sie darf
    /// `image/png` behaupten und trotzdem etwas anderes enthalten.
    func testAnArchivedSubresourceThatIsNoImageIsDropped() throws {
        let resolution = try resolveImages(
            "<img src=\"https://x.test/evil.png\" alt=\"A\">",
            subresources: ["https://x.test/evil.png": .init(
                data: Data("<html><script src=\"http://x.test/x.js\"></script></html>".utf8),
                mimeType: "image/png"
            )]
        )

        XCTAssertFalse(resolution.html.contains("external/"), resolution.html)
        XCTAssertEqual(resolution.missingImagesDropped, 1)
    }

    /// `?` und `#` trennen im URL-Text Query und Fragment ab, im Dateinamen
    /// sind sie erlaubt. `Skizze #1.png` wurde vorher auf `Skizze ` gekürzt und
    /// galt als fehlend — kodiert wie unkodiert.
    func testAHashInAFileNameStillFindsTheImage() throws {
        let source = root.appendingPathComponent("quelle3", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Self.pngBytes.write(to: source.appendingPathComponent("Skizze #1.png"))

        let resolution = try resolveImages(
            "<img src=\"Skizze #1.png\" alt=\"R\"><img src=\"Skizze%20%231.png\" alt=\"K\">",
            baseDirectory: source
        )

        XCTAssertEqual(resolution.missingImagesDropped, 0, resolution.html)
        // Beide Verweise teilen sich eine Kopie.
        XCTAssertEqual(resolution.html.components(separatedBy: "external/local01.png").count, 3, resolution.html)
    }

    /// Ein `>` innerhalb eines Attributwerts beendet das Tag nicht. Vorher
    /// endete der Treffer schon im Alt-Text: Das echte Bild ging verloren, und
    /// der Rest des Tags stand wörtlich im Ergebnis.
    func testAGreaterThanSignInAnAttributeDoesNotEndTheImageTag() throws {
        let source = root.appendingPathComponent("quelle2", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Self.pngBytes.write(to: source.appendingPathComponent("echt.png"))

        let resolution = try resolveImages(
            "<img alt=\"Breite > Höhe\" src=\"echt.png\">", baseDirectory: source
        )

        XCTAssertTrue(resolution.html.contains("external/local01.png"), resolution.html)
        XCTAssertFalse(resolution.html.contains("src=\"echt.png\""), resolution.html)
        XCTAssertEqual(resolution.missingImagesDropped, 0)
    }

}
