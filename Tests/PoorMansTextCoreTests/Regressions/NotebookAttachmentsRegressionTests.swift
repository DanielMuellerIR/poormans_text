import Foundation
import XCTest
@testable import PoorMansTextCore

final class NotebookAttachmentsRegressionTests: XCTestCase {
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

    func testNotebookKeepsCRLFCodeAndLiteralOuterTargetAndResolvesNonbreakingSpaceAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try RegressionFixtures.png()
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

    func testNotebookReferenceAttachmentReachesRealConversion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try RegressionFixtures.png()
        for (index, source) in ["![image](attachment:pic.png)", "![image](\nattachment:pic.png\n)", "> - ![image](\n>   attachment:pic.png\n>   \"title\n>   continued\")", "![image][id]\n\n[id]: attachment:pic.png", "> ![image][id]\n>\n> [id]: attachment:pic.png", "![image][id]\n\n[id]:\n  attachment:pic.png", "![x][id]\n\n[id]: attachment:pic.png \"first\nsecond\"", "![x][long label]\n\n[long\nlabel]: attachment:pic.png", #"![x](attachment:a\(b\).png)"#, "![x](attachment:a&lpar;b&rpar;.png)", (0..<4_097).map { "[x](missing\($0).png" }.joined(separator: "\n") + "\n\n![image](attachment:pic.png)"].enumerated() {
            let notebook: [String: Any] = ["nbformat": 4, "nbformat_minor": 5, "metadata": [:], "cells": [
                ["cell_type": "markdown", "metadata": [:], "source": source,
                 "attachments": ["pic.png": ["image/png": png.base64EncodedString()], "a(b).png": ["image/png": png.base64EncodedString()]]]
            ]]
            let input = root.appendingPathComponent("cell\(index).ipynb")
            try JSONSerialization.data(withJSONObject: notebook).write(to: input)
            let originalBytes = try Data(contentsOf: input)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: input))
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertFalse(markdown.contains("attachment:"), markdown)
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: input), originalBytes)
            XCTAssertEqual(try Data(contentsOf: result.assets[0]), png)
            XCTAssertTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
        }
    }

    func testNotebookReferenceBlockBoundariesAndFollowingTitles() throws {
        let root = try makeRegressionDirectory()
        let literal = "![x][long label]\n\n[long\n# heading\nlabel]: attachment:pic.png\n\n[long\n```\nlabel]: attachment:pic.png\n```"
        let titled = "[id]: #anchor\n\"title `\"\n![x](attachment:pic.png)\n` end"
        for (index, markdown) in [literal, titled].enumerated() {
            let source = root.appendingPathComponent("book\(index).ipynb")
            let json: [String: Any] = ["nbformat": 4, "nbformat_minor": 5, "metadata": [:], "cells": [
                ["cell_type": "markdown", "metadata": [:], "source": markdown,
                 "attachments": ["pic.png": ["image/png": try RegressionFixtures.png().base64EncodedString()]]]
            ]]
            let bytes = try JSONSerialization.data(withJSONObject: json)
            try bytes.write(to: source)
            let rewritten = MarkdownLinkTargetRewriter.replacing(in: markdown, from: "attachment:pic.png", to: "images/image1.png")
            let expected = index == 0 ? markdown : markdown.replacingOccurrences(of: "![x](attachment:pic.png)", with: "![x](images/image1.png)")
            XCTAssertEqual(rewritten, expected)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
                destination: .directory(root.appendingPathComponent("book-output\(index)"))))
            let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
            if index == 0 {
                XCTAssertEqual(output.components(separatedBy: "attachment:pic.png").count - 1, 2)
                XCTAssertTrue(output.contains("# heading"))
            } else {
                XCTAssertTrue(output.contains("![x](images/image1.png)"), output)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), try RegressionFixtures.png())
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
        for title in ["'title `\ncontinued'", "(title `\ncontinued)"] {
            let source = "[id]: #anchor\n\(title)\n![x](attachment:pic.png)\n` end"
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: source, from: "attachment:pic.png", to: "images/p.png"),
                source.replacingOccurrences(of: "![x](attachment:pic.png)", with: "![x](images/p.png)"))
        }
    }
}
