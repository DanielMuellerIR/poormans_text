import Foundation
import XCTest
@testable import PoorMansTextCore

final class ENEXReaderTests: XCTestCase {
    private func archive(_ content: String, fields: String = "", title: String = "Grüße 🙂") -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE en-export SYSTEM \"https://xml.evernote.com/pub/evernote-export4.dtd\">\n<en-export><note><title>" + title + "</title><content><![CDATA[" + content + "]]></content>" + fields + "</note></en-export>").utf8)
    }

    func testExportVariantsUnicodeMetadataAndUnknownDatesArePreserved() throws {
        for version in [2, 3, 4] {
            let bytes = archive("<en-note>BODY_MARKER</en-note>", fields: "<created>20261018T051000Z</created><updated>10101T000000Z</updated><tag>one</tag><tag>Grüße</tag><note-attributes><author>Author</author></note-attributes>")
            let input = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "export4.dtd", with: "export\(version).dtd").utf8)
            let result = try ENEXReader.read(input)
            XCTAssertEqual(result.notes.count, 1)
            let note = try XCTUnwrap(result.notes.first)
            XCTAssertEqual(note.title, "Grüße 🙂")
            XCTAssertEqual(note.metadata.keywords, ["one", "Grüße"])
            XCTAssertEqual(note.metadata.author, "Author")
            XCTAssertEqual(note.metadata.created.map(DocumentMetadata.iso8601), "2026-10-18T05:10:00Z")
            XCTAssertNil(note.metadata.modified)
            XCTAssertEqual(note.warnings.map(\.code), ["enex.invalidDate"])
            XCTAssertEqual(try ENEXReader.field("updated", in: note.node), "10101T000000Z")
        }
    }

    func testDTDIsDeclarativeAndEntityDeclarationsAreRejected() throws {
        let bad = [
            #"<!DOCTYPE en-export SYSTEM "http://127.0.0.1:9/steal.dtd"><en-export/>"#,
            #"<!DOCTYPE en-export [<!ENTITY x "EXPANDED">]><en-export><note><title>&x;</title><content/></note></en-export>"#,
            #"<!DOCTYPE en-export [<!ENTITY x SYSTEM "file:///etc/passwd">]><en-export><note><title>&x;</title><content/></note></en-export>"#,
            #"<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export9.dtd"><en-export/>"#,
            #"<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd" [<!ENTITY x "EVIL">]><en-export/>"#,
            #"<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd'><en-export/>"#
        ]
        for text in bad { XCTAssertThrowsError(try ENEXReader.read(Data(text.utf8))) }
        let valid = #"<!DOCTYPE en-export PUBLIC "en-export" "http://xml.evernote.com/pub/evernote-export3.dtd"><en-export/>"#
        XCTAssertTrue(try ENEXReader.read(Data(valid.utf8)).notes.isEmpty)
    }

    func testENMLCharacterEntitiesAndCDATAKeepDistinctMeaning() throws {
        let root = try ENEXXML.parse(#"<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>A&nbsp;B &euro; &amp; &lt; <![CDATA[&nbsp; <literal>]]></en-note>"#, root: "en-note")
        XCTAssertEqual(root.text, "A\u{00A0}B € & < &nbsp; <literal>")
        XCTAssertThrowsError(try ENEXXML.parse("<en-note>&invented;</en-note>", root: "en-note"))
        XCTAssertThrowsError(try ENEXXML.parse("<!DOCTYPE en-note [<!ENTITY x 'EXPANDED'>]><en-note>&x;</en-note>", root: "en-note"))
    }

    func testDuplicateFieldsUnexpectedRootsAndXMLBudgetsFail() throws {
        for text in ["<wrong/>", "<en-export><unknown/></en-export>", "<en-export>unexpected text</en-export>",
                     "<en-export><note><title>A</title><title>B</title><content/></note></en-export>",
                     "<en-export><note><title>A</title></note></en-export>",
                     "<en-export><note><title>A</title><content><en-note/></content></note></en-export>"] {
            XCTAssertThrowsError(try ENEXReader.read(Data(text.utf8)))
        }
        XCTAssertThrowsError(try ENEXReader.read(Data(repeating: 32, count: ENEXReader.maximumSourceBytes + 1)))
        let deep = "<en-note>" + String(repeating: "<div>", count: 130) + "body" + String(repeating: "</div>", count: 130) + "</en-note>"
        XCTAssertThrowsError(try ENEXXML.parse(deep, root: "en-note"))
        XCTAssertThrowsError(try ENEXXML.parse(String(repeating: " ", count: 16_385) + "<en-note/>", root: "en-note"))
    }
}
