import Foundation
import XCTest
@testable import PoorMansTextCore

final class MarkdownReferenceLinksRegressionTests: XCTestCase {
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

    func testReferenceTargetsAreSharedByObservationAndReplacement() throws {
        let markdown = "![image][id]\n\n[id]: attachment:pic.png \"title\"\n\n```\n[example]: ignored.png\n```"
        let candidates = try MarkdownLinkTargetRewriter.resourceCandidates(in: markdown, maximum: 10, checking: {})
        XCTAssertEqual(candidates, ["attachment:pic.png"])
        let rewritten = MarkdownLinkTargetRewriter.replacing(in: markdown, mapping: ["attachment:pic.png": "images/image01.png"])
        XCTAssertTrue(rewritten.contains("[id]: images/image01.png \"title\""), rewritten)
        XCTAssertTrue(rewritten.contains("[example]: ignored.png"))
    }

    func testReferenceDefinitionsCannotInterruptParagraphsOrCarryInvalidTitles() throws {
        for source in ["ordinary text\n[id]: attachment:pic.png", "[id]: attachment:pic.png stray words", "[id]: <attachment:pic.png>suffix", "[id]: attachment:pic.png \"unfinished"] {
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: source, maximum: 10, checking: {}), [])
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: source, mapping: ["attachment:pic.png": "image.png"]), source)
        }
    }

    func testMultilineReferenceDefinitionsPreserveTheirSourceRanges() throws {
        for source in [
            "![x][id]\n\n[id]: attachment:pic.png \"first\nsecond\"",
            "![x][long label]\n\n[long\nlabel]: attachment:pic.png",
            "![x][id]\n\n[id]:\n    attachment:pic.png",
            "![x][id]\n\n[id]: attachment:pic.png \"first\n    second\"",
            "> ![x][long label]\n>\n> [long\n> label]:\n>   attachment:pic.png \"first\n> second\""
        ] {
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: source, maximum: 1, checking: {}), ["attachment:pic.png"])
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: source, mapping: ["attachment:pic.png": "images/pic.png"]),
                           source.replacingOccurrences(of: "attachment:pic.png", with: "images/pic.png"))
        }
    }

    func testReferenceTitlesAllowNonInterruptingHTMLAndLongContinuation() throws {
        for separator in [" ", "\n"] {
            let markdown = "![x][id]\n\n[id]: attachment:pic.png" + separator + "\"first\n<span>\nlast\""
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: markdown, maximum: 10, checking: {}), ["attachment:pic.png"])
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: markdown, from: "attachment:pic.png", to: "images/p.png"),
                           markdown.replacingOccurrences(of: "attachment:pic.png", with: "images/p.png"))
        }
        let markdown = "[id]: attachment:pic.png\n\"first\n" + String(repeating: "abcdefghijklmnopqrst\n", count: 8_000) + "last\"\n\n![x][id]"
        let start = Date()
        XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: markdown, maximum: 10, checking: {}), ["attachment:pic.png"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
