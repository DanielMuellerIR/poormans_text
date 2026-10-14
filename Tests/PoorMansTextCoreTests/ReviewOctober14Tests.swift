import Foundation
import XCTest
@testable import PoorMansTextCore

final class ReviewOctober14Tests: XCTestCase {
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

    func testNotebookKeepsCRLFCodeAndLiteralOuterTargetAndResolvesNonbreakingSpaceAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
        let attachmentName = "a\u{00A0}b.png"
        let cell = "[first](first.png)\r\n\r\n    [code](code.png)\r\n\r\n"
            + "[outer [inner](inner.png)](outer.png) [last](last.png)\r\n"
            + "![image](attachment:" + attachmentName + ")"
        let source = root.appendingPathComponent("windows.ipynb")
        let original = try JSONSerialization.data(withJSONObject: ["nbformat": 4, "cells": [
            ["cell_type": "markdown", "source": cell, "attachments": [attachmentName: ["image/png": image.base64EncodedString()]]]
        ]])
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(output.contains("    [code](code.png)"), output)
        XCTAssertTrue(output.contains("[outer [inner](#unavailable-resource)](outer.png) [last](#unavailable-resource)"), output)
        XCTAssertEqual(output.components(separatedBy: "#unavailable-resource").count - 1, 3)
        XCTAssertFalse(output.contains("attachment:"), output)
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertEqual(try Data(contentsOf: result.assets[0]), image)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let parsed = try ProcessRunner.run(executable: PandocTool.resolve(nil),
            arguments: ["--sandbox", "--from=gfm", "--to=json", result.markdownFile.path], currentDirectory: root,
            captureStandardOutput: true, timeout: 30)
        XCTAssertEqual(parsed.status, 0)
        XCTAssertTrue(parsed.standardOutput.contains("Image"))
        XCTAssertFalse(parsed.standardOutput.contains("attachment:"))
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
}
