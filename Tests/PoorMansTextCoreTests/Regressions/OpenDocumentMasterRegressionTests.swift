import Foundation
import XCTest
@testable import PoorMansTextCore

final class OpenDocumentMasterRegressionTests: XCTestCase {
    /// Der Weg, auf dem eine FIFO trotz der `stat`-Prüfung der Eingabe erreichbar
    /// war: Ein Masterdokument verweist auf sie als Abschnittsdatei.
    func testMasterDocumentWithAFIFOSectionFailsInsteadOfHanging() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let masterURL = temporaryDirectory.appendingPathComponent("Buch.odm")
        try ZIPFixtureBuilder.odmPackage(contentXML: """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:xlink="http://www.w3.org/1999/xlink">
          <office:body><office:text>
            <text:p>Master introduction.</text:p>
            <text:section text:name="Kapitel">
              <text:section-source xlink:href="kapitel.odt" xlink:type="simple"/>
            </text:section>
          </office:text></office:body>
        </office:document-content>
        """).write(to: masterURL)
        let section = temporaryDirectory.appendingPathComponent("kapitel.odt")
        guard mkfifo(section.path, 0o600) == 0 else {
            throw XCTSkip("FIFO konnte nicht angelegt werden: \(String(cString: strerror(errno)))")
        }

        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: masterURL)) { error in
            guard case ConversionError.invalidInput(_, let format, _) = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
            XCTAssertEqual(format, .odm)
        }
    }

    func testMasterHeadingValueStaysOnOneLineAndKeepsMarkupLiteral() {
        XCTAssertEqual(MarkdownEscaping.heading("Kapitel\n# Untergeschoben"), "Kapitel \\# Untergeschoben")
        XCTAssertEqual(MarkdownEscaping.heading("*fett*"), "\\*fett\\*")
        XCTAssertEqual(MarkdownEscaping.heading("a\tb   c"), "a b c")
        XCTAssertEqual(MarkdownEscaping.heading("Bericht 2026"), "Bericht 2026")
    }

    func testMasterDeletedRevisionTextDoesNotBecomeCurrentContent() throws {
        let root = try makeRegressionDirectory()
        let content = #"<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:tracked-changes><text:changed-region text:id="old"><text:deletion><text:p>DELETEDTOKEN</text:p></text:deletion></text:changed-region></text:tracked-changes><text:p>CURRENTTOKEN</text:p></office:text></office:body></office:document-content>"#
        let bytes = try ZIPFixtureBuilder.odmPackage(contentXML: content)
        let source = root.appendingPathComponent("revision.odm")
        try bytes.write(to: source)
        let converter = DocumentConverter()
        XCTAssertTrue(try converter.inspect(source).expectedWarnings.contains { $0.code == "openDocument.changesNotPreserved" })
        let result = try converter.convert(ConversionRequest(inputURL: source))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertFalse(text.contains("DELETEDTOKEN"), text)
        XCTAssertEqual(text.components(separatedBy: "CURRENTTOKEN").count - 1, 1)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "openDocument.changesNotPreserved" })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
