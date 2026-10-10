import Foundation
import XCTest
@testable import PoorMansTextCore

final class ReviewOctober10Tests: XCTestCase {
    func testIgnoredRTFDestinationBetweenSurrogatesPreservesVisibleText() throws {
        try withDirectory { root in
            let rtf = #"{\rtf1\ansi\uc0 A\u-10179{\*\unknown hidden {\uc2\u56832??}\bin3 {}X}\u-8704 B}"#
            let source = root.appendingPathComponent("source.rtf")
            let original = Data(rtf.utf8)
            try original.write(to: source)
            let reference = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/textutil"),
                arguments: ["-convert", "txt", "-stdout", source.path], currentDirectory: root, captureStandardOutput: true)
            XCTAssertEqual(reference.status, 0)
            XCTAssertEqual(reference.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "A😀B")
            let result = try RichTextConverter().convert(inputURL: source)
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(markdown.trimmingCharacters(in: .whitespacesAndNewlines), "A😀B")
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
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
        try withDirectory { root in
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

    func testHTMLAttributeLegacyReferencesRespectAttributeBoundaries() throws {
        for (input, expected) in [("a&amp.png", "a&.png"), ("a&amp;.png", "a&.png"),
                                  ("a&copy.png", "a©.png"), ("a&copy;.png", "a©.png"),
                                  ("&amp", "&"), ("&notin;", "∉"), ("&notin", "&notin"),
                                  ("&copyx", "&copyx"), ("&copy7", "&copy7"),
                                  ("&copy=", "&copy="), ("&apos.png", "&apos.png"),
                                  ("&copy;x", "©x"), ("&bogus;", "&bogus;")] {
            XCTAssertEqual(try HTMLImageAttributes.decodedValue(input), expected, input)
        }
        try withDirectory { root in
            let fixture = try FixtureFactory.createRichRTF(in: root)
            for name in ["a&.png", "a©.png"] {
                try fixture.imageData.write(to: root.appendingPathComponent(name))
            }
            let original = Data(#"<html><body><p>START</p><img src="a&amp.png"><img src="a&amp;.png"><img src="a&copy.png"><img src="a&copy;.png"><p>END</p></body></html>"#.utf8)
            let source = root.appendingPathComponent("images.html")
            try original.write(to: source)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
            XCTAssertEqual(result.assets.count, 2)
            for asset in result.assets { XCTAssertEqual(try Data(contentsOf: asset), fixture.imageData) }
            XCTAssertFalse(result.diagnostics.contains { $0.code == ConversionWarning.missingImagesDropped(1).code })
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(markdown.components(separatedBy: "![").count - 1, 4, markdown)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testIncompleteInlineTitlesHaveBoundedWorkAndRemainCancellable() throws {
        func scan(_ count: Int) throws -> Int {
            let text = Array(repeating: "[x](old.png (", count: count).joined(separator: " ")
            var checks = 0
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: text, maximum: 10) { checks += 1 }, [])
            return checks
        }
        let small = try scan(2_000)
        let large = try scan(4_000)
        XCTAssertLessThanOrEqual(large, small * 3)
        struct Cancelled: Error {}
        var checks = 0
        XCTAssertThrowsError(try MarkdownLinkTargetRewriter.resourceCandidates(
            in: String(repeating: "[x](old.png ( ", count: 16_000), maximum: 10) {
                checks += 1
                if checks == 20 { throw Cancelled() }
            }) { XCTAssertTrue($0 is Cancelled) }
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(
            in: #"[bad](old.png ( unfinished [good](old.png "ok")"#, from: "old.png", to: "new.png"),
            #"[bad](old.png ( unfinished [good](new.png "ok")"#)
    }

    func testMultilineReferenceTitleWithEscapedQuotesPreservesFollowingLink() throws {
        let text = "[ref]: old.png\n\"start\n" + String(repeating: "escaped \\\"\n", count: 2_000)
            + "end\"\n\n[ref]\n[good](old.png)"
        let rewritten = MarkdownLinkTargetRewriter.replacing(in: text, from: "old.png", to: "new.png")
        XCTAssertEqual(rewritten, text.replacingOccurrences(of: "old.png", with: "new.png"))
        XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: text, maximum: 10, checking: {}), ["old.png"])
        struct Cancelled: Error {}
        var checks = 0
        XCTAssertThrowsError(try MarkdownLinkTargetRewriter.resourceCandidates(in: text, maximum: 10) {
            checks += 1
            if checks == 20 { throw Cancelled() }
        }) { XCTAssertTrue($0 is Cancelled) }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewOctober10-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
