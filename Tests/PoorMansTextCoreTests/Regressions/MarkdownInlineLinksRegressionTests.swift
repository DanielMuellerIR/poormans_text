import Foundation
import XCTest
@testable import PoorMansTextCore

final class MarkdownInlineLinksRegressionTests: XCTestCase {
    func testLinkTitleBackticksDoNotHideTheFollowingAssetLink() {
        let markdown = #"[first](images/old.png "title ` literal") [second](images/old.png) `later`"#
        XCTAssertEqual(
            rewrite(markdown),
            #"[first](images/new.png "title ` literal") [second](images/new.png) `later`"#
        )
    }

    func testManySingleLineCodeSpansDoNotRescanTheRemainingParagraph() {
        let line = "`code` [asset](images/old.png)"
        let markdown = Array(repeating: line, count: 5_000).joined(separator: "\n")
        let rewritten = rewrite(markdown)
        XCTAssertEqual(rewritten.components(separatedBy: "images/new.png").count - 1, 5_000)
    }

    private func rewrite(_ markdown: String) -> String {
        MarkdownLinkTargetRewriter.replacing(
            in: markdown,
            from: "images/old.png",
            to: "images/new.png"
        )
    }

    func testMalformedNestedLinkDestinationsAreLinearAndCancellable() throws {
        let input = String(repeating: "[x](", count: 40_000) + "\n\n[real](old.png)"
        var checks = 0
        let output = try MarkdownLinkTargetRewriter.replacing(in: input, mapping: ["old.png": "new.png"], checking: { checks += 1 })
        XCTAssertEqual(output, String(repeating: "[x](", count: 40_000) + "\n\n[real](new.png)")
        XCTAssertGreaterThan(checks, 100)
        enum Stopped: Error { case cancelled }
        checks = 0
        XCTAssertThrowsError(try MarkdownLinkTargetRewriter.replacing(in: input, mapping: ["old.png": "new.png"], checking: {
            checks += 1
            if checks == 20 { throw Stopped.cancelled }
        }))
        XCTAssertEqual(checks, 20)
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

    func testNestedParenthesisTitleRemainsLiteralAndFollowingLinkIsRewritten() throws {
        let literal = "[x](old.png (bad (nested) ) tail "
        let markdown = literal + "[good](old.png)"
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: markdown, from: "old.png", to: "new.png"),
                       literal + "[good](new.png)")
        XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: literal, maximum: 10, checking: {}), [])
        for title in [#"valid \(nested\)"#, "plain", #"escaped \\ backslash"#] {
            let link = "[x](old.png (\(title)))"
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: link, from: "old.png", to: "new.png"),
                           "[x](new.png (\(title)))")
        }
        let quoted = #"[x](old.png "valid (nested)")"#
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: quoted, from: "old.png", to: "new.png"),
                       quoted.replacingOccurrences(of: "old.png", with: "new.png"))
    }

    func testLogicalLineEndingsProtectCodeAndPreserveOriginalBytes() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let markdown = "[first](old.png)" + newline + newline
                + "    [code](code.png)" + newline + newline + "[last](last.png)" + newline
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: markdown, maximum: 10, checking: {}),
                           ["old.png", "last.png"])
            // Pandocs cmark-Frontend erkennt einzelnes CR nicht als Umbruch;
            // für diese Gegenprobe die laut CommonMark gültigen Zeilen normalisieren.
            let readerInput = newline == "\r" ? markdown.replacingOccurrences(of: "\r", with: "\n") : markdown
            XCTAssertEqual(try readerTargets(readerInput), ["old.png", "last.png"])
            let expected = markdown.replacingOccurrences(of: "old.png", with: "new.png")
                .replacingOccurrences(of: "last.png", with: "end.png")
            let output = MarkdownLinkTargetRewriter.replacing(in: markdown,
                mapping: ["old.png": "new.png", "code.png": "wrong.png", "last.png": "end.png"])
            XCTAssertEqual(Data(output.utf8), Data(expected.utf8))
            let definition = "[ref]: old.png" + newline + "  \"title\"" + newline + newline + "[ref]"
            XCTAssertEqual(Data(MarkdownLinkTargetRewriter.replacing(in: definition, from: "old.png", to: "new.png").utf8),
                           Data(definition.replacingOccurrences(of: "old.png", with: "new.png").utf8))
        }
    }

    func testInnerLinkDisablesOuterLinksButAllowsImages() throws {
        let cases: [(String, Set<String>)] = [
            ("[outer [inner](inner.png)](outer.png) [next](next.png)", ["inner.png", "next.png"]),
            ("![outer [inner](inner.png)](outer.png) [next](next.png)", ["inner.png", "outer.png", "next.png"]),
            ("[outer ![inner](inner.png)](outer.png) [next](next.png)", ["inner.png", "outer.png", "next.png"]),
            ("[[label]](outer.png)", ["outer.png"]),
            (#"\![outer [inner](inner.png)](outer.png)"#, ["inner.png"])
        ]
        for (markdown, targets) in cases {
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: markdown, maximum: 10, checking: {}), targets)
            XCTAssertEqual(try readerTargets(markdown), targets)
            let mapping = Dictionary(uniqueKeysWithValues: targets.map { ($0, "new-" + $0) })
                .merging(["outer.png": "new-outer.png"]) { a, _ in a }
            let expected = targets.reduce(markdown) { $0.replacingOccurrences(of: $1, with: "new-" + $1) }
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: markdown, mapping: mapping), expected)
        }
    }

    func testNonASCIIWhitespaceBelongsToDestinations() throws {
        for space in ["\u{00A0}", "\u{2003}", "\u{202F}"] {
            for target in ["attachment:a" + space + "b.png", "attachment:a(" + space + "b).png"] {
                let markdown = "![image](" + target + ") [next](next.png)"
                XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: markdown, maximum: 10, checking: {}),
                               [target, "next.png"])
                XCTAssertEqual(try readerTargets(markdown), [target, "next.png"])
                XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: markdown, from: target, to: "images/picture.png"),
                               "![image](images/picture.png) [next](next.png)")
            }
        }
    }

    private func readerTargets(_ markdown: String) throws -> Set<String> {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(markdown.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let parsed = try ProcessRunner.run(executable: PandocTool.resolve(nil),
            arguments: ["--sandbox", "--from=gfm", "--to=json", file.path],
            currentDirectory: file.deletingLastPathComponent(), captureStandardOutput: true, timeout: 30)
        XCTAssertEqual(parsed.status, 0)
        let document = try JSONSerialization.jsonObject(with: Data(parsed.standardOutput.utf8))
        var targets = Set<String>()
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                if let type = object["t"] as? String, type == "Link" || type == "Image",
                   let content = object["c"] as? [Any], let target = content.last as? [String], let path = target.first {
                    targets.insert(path.removingPercentEncoding ?? path)
                }
                object.values.forEach(visit)
            } else if let array = value as? [Any] { array.forEach(visit) }
        }
        visit(document)
        return targets
    }

    func testMultilineInlineLinksPreserveContainersAndFollowingText() throws {
        let target = "attachment:pic.png"
        let sources = [
            "![x](\nattachment:pic.png\n) tail [y](attachment:pic.png)",
            "![x](attachment:pic.png\n\"title `literal`\") tail [y](attachment:pic.png)",
            "> ![x](\n> attachment:pic.png\n> ) tail [y](attachment:pic.png)",
            "- ![x](\n  attachment:pic.png\n  \"title\") tail [y](attachment:pic.png)",
            "![x](attachment:pic.png )",
            "> - ![x](\n>   attachment:pic.png\n>   \"Titel\n>   fortgesetzt\") tail [y](attachment:pic.png)",
            "[web](https://example.test\n\"Title`literal\") ![x](attachment:pic.png)"
        ]
        for source in sources {
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: source, maximum: 2, checking: {}), source.hasPrefix("[web]") ? [target, "https://example.test"] : [target])
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: source, mapping: [target: "images/pic.png"]),
                           source.replacingOccurrences(of: target, with: "images/pic.png"))
        }
        for source in ["`![x](\nattachment:pic.png\n)`", "![x](\n\nattachment:pic.png\n)", "![x](\n# heading\nattachment:pic.png)", "```\n![x](\nattachment:pic.png\n)\n```"] {
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: source, maximum: 1, checking: {}), [])
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: source, mapping: [target: "images/pic.png"]), source)
        }
    }

    func testLongInlineBlockChecksCancellationDuringBothScans() throws {
        let source = String(repeating: "a", count: 100_000) + " ![x](attachment:pic.png)"
        for threshold in [10, 150] {
            var checks = 0
            XCTAssertThrowsError(try MarkdownLinkTargetRewriter.resourceCandidates(in: source, maximum: 1, checking: {
                checks += 1
                if checks == threshold { throw ConversionError.cancelled }
            })) { error in
                guard case ConversionError.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(checks, threshold)
        }
        let ticks = String(repeating: "`literal` ", count: 20_000) + "![x](attachment:pic.png)"
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: ticks, mapping: ["attachment:pic.png": "images/pic.png"]),
                       ticks.replacingOccurrences(of: "attachment:pic.png", with: "images/pic.png"))
    }

    func testMarkdownEscapesAndCharacterReferencesResolveBeforeMapping() throws {
        for target in [#"attachment:a\(b\).png"#, "attachment:a&#40;b&#x29;.png", "attachment:a&lpar;b&rpar;.png"] {
            let source = "![x](\(target))\n\n[id]: \(target)"
            XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: source, maximum: 1, checking: {}), ["attachment:a(b).png"])
            let rewritten = MarkdownLinkTargetRewriter.replacing(in: source, mapping: ["attachment:a(b).png": "images/pic.png"])
            XCTAssertEqual(rewritten, "![x](images/pic.png)\n\n[id]: images/pic.png")
        }
    }

    func testUnfinishedLiteralLinksDoNotConsumeTheResourceBudget() throws {
        let literal = (0..<4_097).map { "[x](missing\($0).png" }.joined(separator: "\n")
        XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: literal, maximum: 1, checking: {}), [])
        XCTAssertEqual(try MarkdownLinkTargetRewriter.resourceCandidates(in: literal + "\n\n![x](real.png)", maximum: 1, checking: {}), ["real.png"])
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: literal, mapping: ["missing0.png": "changed.png"]), literal)
    }
}
