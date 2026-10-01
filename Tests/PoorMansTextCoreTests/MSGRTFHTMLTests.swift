import Foundation
import XCTest
@testable import PoorMansTextCore

final class MSGRTFHTMLTests: XCTestCase {
    func testEscapesUnicodeAndSuppressedRendering() throws {
        let source = Data(#"{\rtf1\ansi\ansicpg1252\fromhtml1{\fonttbl{\f0 Arial;}}{\*\htmltag64}<p>Gr\'fc\u223?e \u-10179?\u-8704?{\htmlrtf hidden}{\*\htmltag64}</p>}"#.utf8)
        XCTAssertEqual(try MSGRTFHTML.decode(source), "<p>Grüße 😀</p>")
        XCTAssertNil(try MSGRTFHTML.decode(Data(#"{\rtf1 Plain}"#.utf8)))
    }

    func testFontCharsetsAndExplicitCodepage() throws {
        for font in [#"\fcharset204"#, #"\cpg1251"#] {
            let source = Data((#"{\rtf1\ansi\fromhtml1{\fonttbl{\f0"# + font + #" Arial;}}{\*\htmltag64}<p>\f0\'cf\'f0\'e8\'e2\'e5\'f2</p>}"#).utf8)
            XCTAssertEqual(try MSGRTFHTML.decode(source), "<p>Привет</p>")
        }
    }

    func testNativeFallbackNormalizationHonorsGroupsEscapesAndBinary() throws {
        let pairs = [
            (#"{\rtf1\uc2\u252??e}"#, #"{\rtf1\uc2\uc0\u252 e}"#),
            (#"{\rtf1\uc1\u252\'3fe}"#, #"{\rtf1\uc1\uc0\u252 e}"#),
            (#"{\rtf1{\uc2\u252??}\u223?e}"#, #"{\rtf1{\uc2\uc0\u252 }\uc0\u223 e}"#),
            (#"{\rtf1\u252\tab e {\pict\bin3 {}\}}"#, #"{\rtf1\uc0\u252 e {\pict\bin3 {}\}}"#)
        ]
        for (source, expected) in pairs {
            let result = try MSGRTFHTML.prepare(Data(source.utf8))
            XCTAssertNil(result.html)
            XCTAssertEqual(result.rtf, Data(expected.utf8))
        }
    }

    func testRejectsBrokenGroupsBinaryAndUnicode() throws {
        for raw in [#"{\rtf1\fromhtml1"#, #"{\rtf1\fromhtml1\bin100 abc}"#,
                    #"{\rtf1\fromhtml1\u-10179?}"#, #"{\rtf1\fromhtml1\'zz}"#] {
            XCTAssertThrowsError(try MSGRTFHTML.decode(Data(raw.utf8)))
        }
    }

    func testExternalHTMLMatchesIndependentDecoder() throws {
        guard let path = ProcessInfo.processInfo.environment["POORMANS_MSG_RTF_REFERENCE"] else {
            throw XCTSkip("External RTF HTML corpus not configured")
        }
        struct Body: Decodable { let rtf: String; let html: String? }
        let refs = try JSONDecoder().decode([Body].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var count = 0
        for ref in refs {
            let bytes = try XCTUnwrap(Data(base64Encoded: ref.rtf))
            if let expected = ref.html {
                let actual = try XCTUnwrap(MSGRTFHTML.decode(bytes))
                XCTAssertEqual(normalized(actual), normalized(expected))
                count += 1
            } else { XCTAssertNil(try MSGRTFHTML.decode(bytes)) }
        }
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    private func normalized(_ html: String) -> String {
        html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
