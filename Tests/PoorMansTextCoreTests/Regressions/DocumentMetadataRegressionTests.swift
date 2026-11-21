import Foundation
import XCTest
@testable import PoorMansTextCore

final class DocumentMetadataRegressionTests: XCTestCase {
    /// Ein Wagenrücklauf im Titel eines fremden Dokuments blieb unmaskiert, weil
    /// die Maskierung über `Character` lief und ein CRLF-Paar in Swift EIN
    /// `Character` ist, das weder auf `"\n"` noch auf `"\r"` passt. Ein solcher
    /// Titel konnte den YAML-Kopf schließen und eigenen Markdown-Inhalt
    /// anhängen.
    func testAControlCharacterInTheTitleCannotBreakOutOfTheFrontmatter() throws {
        let root = try makeRegressionDirectory()
        for injected in ["Harmlos&#13;---&#13;# Eingeschleust", "Harmlos&#13;&#10;---&#13;&#10;# Eingeschleust"] {
            let sourceURL = root.appendingPathComponent("Tabelle-\(UUID().uuidString).ods")
            try RegressionFixtures.ods(meta: "<dc:title>\(injected)</dc:title>").write(to: sourceURL)

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
}
