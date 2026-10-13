import Foundation
import XCTest
@testable import PoorMansTextCore

final class ReviewOctober13Tests: XCTestCase {
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

    func testNotebookPreservesLiteralTargetBeforeRealMissingLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let literal = "[x](old.png (bad (nested) ) tail "
        let source = root.appendingPathComponent("title.ipynb")
        let notebook: [String: Any] = ["nbformat": 4, "nbformat_minor": 5, "metadata": [:], "cells": [
            ["cell_type": "markdown", "metadata": [:], "source": literal + "[good](old.png)"]
        ]]
        let original = try JSONSerialization.data(withJSONObject: notebook)
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(output.contains(literal + "[good](#unavailable-resource)"), output)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
