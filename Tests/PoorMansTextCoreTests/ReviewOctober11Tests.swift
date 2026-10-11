import Foundation
import XCTest
@testable import PoorMansTextCore

final class ReviewOctober11Tests: XCTestCase {
    func testSharedTitleClosingWithInvalidWhitespaceTailScalesWithInput() throws {
        func scan(_ count: Int) throws -> TimeInterval {
            let text = String(repeating: "[x](old.png ( ", count: count)
                + ")" + String(repeating: " ", count: 4 * count) + "X"
            let start = ProcessInfo.processInfo.systemUptime
            let targets = try MarkdownLinkTargetRewriter.resourceCandidates(in: text, maximum: 10, checking: {})
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            XCTAssertEqual(targets, [])
            return elapsed
        }
        _ = try scan(100)
        let small = try scan(2_000)
        let large = try scan(8_000)
        // Vierfache Eingabe darf deutlich unter dem Faktor 16 eines
        // quadratischen Scans bleiben; Spielraum für schwankende Systemlast.
        XCTAssertLessThan(large, small * 8 + 0.1, "2,000: \(small)s; 8,000: \(large)s")
    }

    func testSharedTitleClosingPreservesFollowingLinksAndCancellation() throws {
        for (opener, closer) in [("(", ")"), ("\"", "\""), ("'", "'")] {
            let prefix = String(repeating: "[x](old.png \(opener) ", count: 500)
                + closer + String(repeating: " \t", count: 2_000) + "X "
            let suffix = "[good](old.png \(opener)title\(closer) \t)"
            let text = prefix + suffix
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: text, maximum: 10, checking: {}), ["old.png"])
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: text, from: "old.png", to: "new.png"),
                           prefix + suffix.replacingOccurrences(of: "old.png", with: "new.png"))
        }
        struct Cancelled: Error {}
        var checks = 0
        let text = "[x](old.png (title)" + String(repeating: " ", count: 100_000) + "X"
        XCTAssertThrowsError(try MarkdownLinkTargetRewriter.resourceCandidates(in: text, maximum: 10) {
            checks += 1
            if checks == 20 { throw Cancelled() }
        }) { XCTAssertTrue($0 is Cancelled) }
    }

    func testHTMLNumericReferencesUseHistoricalC1Mappings() throws {
        let expected = ["€", "\u{81}", "‚", "ƒ", "„", "…", "†", "‡", "ˆ", "‰", "Š", "‹", "Œ", "\u{8D}", "Ž", "\u{8F}",
                        "\u{90}", "‘", "’", "“", "”", "•", "–", "—", "˜", "™", "š", "›", "œ", "\u{9D}", "ž", "Ÿ"]
        for (offset, character) in expected.enumerated() {
            let number = 0x80 + offset
            for reference in ["&#\(number);", "&#x\(String(number, radix: 16));", "&#X\(String(number, radix: 16).uppercased())"] {
                XCTAssertEqual(try HTMLImageAttributes.decodedValue("a\(reference).png"), "a\(character).png", reference)
            }
        }
        for (input, output) in [("&#0;", "�"), ("&#xD800;", "�"), ("&#1114112;", "�"),
                                ("&#999999999999999999999;", "�"), ("&#127;", "\u{7F}"),
                                ("&#160;", "\u{A0}"), ("&#x1F600;", "😀"), ("&#xFFFF;", "\u{FFFF}")] {
            XCTAssertEqual(try HTMLImageAttributes.decodedValue(input), output, input)
        }
    }

    func testHTMLNumericImageReferencesPreserveAssetsAndSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewOctober11-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try FixtureFactory.createRichRTF(in: root)
        let images = [(128, "€"), (146, "’"), (150, "–"), (159, "Ÿ")]
        var tags = [String]()
        for (number, character) in images {
            try fixture.imageData.write(to: root.appendingPathComponent("a\(character).png"))
            tags.append("<img src=\"a&#\(number);.png\" alt=\"DEC\(number)\">")
            tags.append("<img src=\"a&#x\(String(number, radix: 16));.png\" alt=\"HEX\(number)\">")
        }
        let original = Data(("<html><body><p>STARTTOKEN</p>" + tags.joined() + "<p>ENDTOKEN</p></body></html>").utf8)
        let source = root.appendingPathComponent("images.html")
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertEqual(result.assets.count, images.count)
        for asset in result.assets { XCTAssertEqual(try Data(contentsOf: asset), fixture.imageData) }
        XCTAssertFalse(result.diagnostics.contains { $0.code == "html.missingImagesDropped" })
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "![").count - 1, images.count * 2, markdown)
        for token in ["STARTTOKEN", "ENDTOKEN"] {
            XCTAssertEqual(markdown.components(separatedBy: token).count - 1, 1, markdown)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        for (_, character) in images {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a\(character).png")), fixture.imageData)
        }
    }
}
