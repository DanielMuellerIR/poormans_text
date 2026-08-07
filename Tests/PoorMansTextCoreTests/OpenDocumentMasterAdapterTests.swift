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

    /// Eine ODF-Notiz mitten im Absatz enthält selbst wieder `text:p`. Vorher
    /// ersetzte der innere Absatz den äußeren, und der Text davor und danach
    /// verschwand still aus dem Ergebnis.
    func testMasterParagraphSurvivesANestedAnnotationParagraph() throws {
        let markdown = try convertedMasterMarkdown(
            body: """
            <text:p>Before the note<office:annotation><text:p>Note</text:p></office:annotation> \
            and after it.</text:p>
            """,
            name: "Annotated"
        )

        let paragraph = try XCTUnwrap(
            markdown.split(separator: "\n").first { $0.contains("Before the note") }
        )
        XCTAssertTrue(paragraph.contains("and after it."), markdown)
        XCTAssertTrue(markdown.contains("Note"), markdown)
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
