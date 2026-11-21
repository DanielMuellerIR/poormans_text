import Foundation
import XCTest
@testable import PoorMansTextCore

final class RichTextMetadataRegressionTests: XCTestCase {
    func testRTFUnicodeHonoursTheFallbackCountAndSurrogatePairs() {
        // U+1F389 (🎉) als Surrogatpaar D83C DF89 → -10180, -8311; `\uc2` verlangt
        // zwei Ersatzzeichen nach jedem `\uN`.
        let rtf = #"{\rtf1\ansi{\info{\title \uc2\u-10180 ??\u-8311 ?? Fest}{\subject \uc0\u8364 x}{\author \u8364 ?x\u228\'e4y}}}"#
        let metadata = RTFInfoParser.parse(Data(rtf.utf8))

        XCTAssertEqual(metadata.title, "🎉 Fest")
        XCTAssertEqual(metadata.subject, "€x")
        XCTAssertEqual(metadata.author, "€xäy")
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

    func testRTFMetadataUnicodeFallbackIsScopedToItsGroup() {
        let rtf = #"{\rtf1\ansi{\info{\title {\uc0\u945}{\u946?}}}Text}"#
        XCTAssertEqual(RTFInfoParser.parse(Data(rtf.utf8)).title, "αβ")
    }

    func testMetadataInheritsUnicodeFallbackFromEnclosingGroups() throws {
        let cases = [
            (#"{\rtf1\ansi\uc0{\info{\title A\u945B}{\author C\u946D}}Text}"#, "AαB", "CβD"),
            (#"{\rtf1\ansi\uc2{\info{\title A\u945??B}{\author C\u946??D}}Text}"#, "AαB", "CβD"),
            (#"{\rtf1\ansi\uc2{\info\uc0{\title A\u945B}{\author C\u946D}}Text}"#, "AαB", "CβD"),
            (#"{\rtf1\ansi\uc0{\fonttbl{\uc2 ignored}}{\info{\title\uc2 A\u945??B}{\author C\u946D}}Text}"#, "AαB", "CβD")
        ]
        for (rtf, title, author) in cases {
            let metadata = RTFInfoParser.parse(Data(rtf.utf8))
            XCTAssertEqual(metadata.title, title)
            XCTAssertEqual(metadata.author, author)
        }
        let root = try makeRegressionDirectory()
        let source = root.appendingPathComponent("metadata.rtf")
        let original = Data(cases[0].0.utf8)
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(
            inputURL: source, options: ConversionOptions(frontmatter: true)))
        XCTAssertEqual(result.metadata.title, "AαB")
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains(#"title: "AαB""#), markdown)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
