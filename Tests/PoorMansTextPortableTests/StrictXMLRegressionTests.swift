import Foundation
#if os(Linux)
import FoundationXML
#endif
import XCTest
@testable import PoorMansTextCore

final class StrictXMLRegressionTests: XCTestCase {
    private final class Delegate: NSObject, XMLParserDelegate {}
    func testMalformedXMLAndENMLAreRejected() throws {
        for text in ["<root><p>broken</root>", "<root><p>unfinished", "<root/ junk>"] {
            XCTAssertFalse(ImportXMLParser.make(Data(text.utf8), delegate: Delegate()).parse(), text)
            XCTAssertThrowsError(try ImportXML.parse(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try ENEXXML.parse("<en-note><p>broken</en-note>", root: "en-note"))
        XCTAssertEqual(try ImportXML.parse(Data("<root><p>valid</p></root>".utf8)).text, "valid")
    }
    func testInternalSubsetsAreRejectedIncludingUnicodeEncodings() throws {
        let source = "<!DOCTYPE root [<!ENTITY text 'EXPANDED'>]><root>&text;</root>"
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let data = try XCTUnwrap(source.data(using: encoding))
            #if os(Linux)
            XCTAssertFalse(ImportXMLParser.make(data, delegate: Delegate()).parse())
            #endif
            XCTAssertThrowsError(try ImportXML.parse(data))
        }
        for prefix in ["<!-- <!DOCTYPE ignored [fake]> -->", "<?probe value='['?>", "<?xml-stylesheet encoding='UTF-7'?>", ""] {
            let valid = prefix + "<!DOCTYPE root SYSTEM 'https://example.invalid/[unused].dtd'><root><![CDATA[<!DOCTYPE literal [text]>]]></root>"
            XCTAssertEqual(try ImportXML.parse(Data(valid.utf8)).text, "<!DOCTYPE literal [text]>")
        }
    }
    func testLateInvalidENMLPublishesNoCollectionAndPreservesSource() throws {
        guard (try? PandocTool.resolve(nil)) != nil else { throw XCTSkip("Pandoc is required for the collection publication regression") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTStrictENML-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.enex")
        let output = root.appendingPathComponent("result")
        let bytes = Data("<en-export><note><title>Valid</title><content><![CDATA[<en-note>ONE</en-note>]]></content></note><note><title>Invalid</title><content><![CDATA[<en-note><p>broken</en-note>]]></content></note></en-export>".utf8)
        try bytes.write(to: source)
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(output))))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["notes.enex"])
    }

    #if os(Linux)
    func testShiftEncodingsCannotHideAnInternalSubset() throws {
        let shiftedBracket = "<?xml version='1.0' encoding='UTF-7'?><!DOCTYPE root +AFs-<!ENTITY body 'EXPANDED'>+AF0-><root>&body;</root>"
        let shiftedDocument = "<?xml version='1.0' encoding='UTF-7'?>+ADwAIQBEAE8AQwBUAFkAUABFACAAcgBvAG8AdAAgAFsAPAAhAEUATgBUAEkAVABZACAAYgBvAGQAeQAgACcARQBYAFAAQQBOAEQARQBEACcAPgBdAD4APAByAG8AbwB0AD4AJgBiAG8AZAB5ADsAPAAvAHIAbwBvAHQAPg-"
        let ebcdic = try XCTUnwrap(Data(base64Encoded: "TG+nlJNApYWZoomWlX598UvwfUCFlYOWhImVh359ycLU8PP3fW9uTFrE1sPj6NfFQJmWlqNAukxaxdXjyePoQIKWhKhAfcXn18HVxMXEfW67bkyZlpajblCCloSoXkxhmZaWo24="))
        for bytes in [Data(shiftedBracket.utf8), Data(shiftedDocument.utf8), ebcdic] {
            let parser = ImportXMLParser.make(bytes, delegate: Delegate())
            XCTAssertFalse(parser.parse())
            XCTAssertTrue(parser.parserError?.localizedDescription.contains("unsupported XML encoding") == true)
            XCTAssertThrowsError(try ImportXML.parse(bytes))
        }
    }
    #endif

    func testUnicodeAndASCIIDeclarationsPreserveTextAndRejectSubsets() throws {
        let encodings: [(String, String.Encoding)] = [("UTF-8", .utf8), ("UTF-16", .utf16),
            ("UTF-16LE", .utf16LittleEndian), ("UTF-16BE", .utf16BigEndian),
            ("UTF-32BE", .utf32BigEndian), ("US-ASCII", .ascii)]
        for (name, encoding) in encodings {
            let header = "<?xml version='1.0' encoding='\(name)'?>"
            let expected = name == "US-ASCII" ? "ASCII" : "Größe"
            let valid = try XCTUnwrap((header + "<root>\(expected)</root>").data(using: encoding))
            XCTAssertEqual(try ImportXML.parse(valid).text, expected, name)
            let invalid = try XCTUnwrap((header + "<!DOCTYPE root [<!ENTITY body 'EXPANDED'>]><root>&body;</root>").data(using: encoding))
            XCTAssertThrowsError(try ImportXML.parse(invalid), name)
        }
    }

    func testCheckedLegacyEncodingsPreserveTextAndRejectSubsets() throws {
        for name in ["ISO-8859-1", "WINDOWS-1252"] {
            let header = Data("<?xml version='1.0' encoding='\(name)'?>".utf8)
            let valid = header + Data("<root>Gr".utf8) + Data([0xF6, 0xDF]) + Data("e</root>".utf8)
            XCTAssertEqual(try ImportXML.parse(valid).text, "Größe", name)
            let invalid = header + Data("<!DOCTYPE root [<!ENTITY body 'EXPANDED'>]><root>&body;</root>".utf8)
            XCTAssertThrowsError(try ImportXML.parse(invalid), name)
        }
    }

    #if os(Linux)
    func testUnsupportedUTF32LittleEndianHasAnExplicitDiagnostic() throws {
        for (name, encoding) in [("UTF-32LE", String.Encoding.utf32LittleEndian), ("UTF-32", .utf32), ("UTF-32", .utf32BigEndian)] {
            let data = try XCTUnwrap(("<?xml version='1.0' encoding='\(name)'?><root>text</root>").data(using: encoding))
            let parser = ImportXMLParser.make(data, delegate: Delegate())
            XCTAssertFalse(parser.parse())
            XCTAssertTrue(parser.parserError?.localizedDescription.contains("unsupported XML encoding") == true)
        }
    }
    #endif

}
