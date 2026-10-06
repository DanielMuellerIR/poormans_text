import Foundation
import ImageIO
import XCTest
@testable import PoorMansTextCore

final class ReviewRegressionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTReview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var png: Data {
        get throws {
            try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
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

    func testSpreadsheetLinkReferencesPreserveLiteralAmpersands() throws {
        for target in ["javascript&colon;alert(1)", "java&#x73;cript&colon;alert(1)", "data&colon;text/html,a", "https://example.invalid/?a=1&b=2"] {
            let workbook = SpreadsheetWorkbook(sheets: [.init(name: "S", rows: [[.init(value: .string("CLICKTOKEN"), displayText: "CLICKTOKEN", formula: nil, linkTarget: target)]])])
            let markdown = try SpreadsheetMarkdownRenderer.render(workbook, sourceURL: root.appendingPathComponent("input.ods"), style: .markdownTable)
            XCTAssertTrue(markdown.contains(target.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")), markdown)
        }
    }

    func testNotebookReferenceBlockBoundariesAndFollowingTitles() throws {
        let literal = "![x][long label]\n\n[long\n# heading\nlabel]: attachment:pic.png\n\n[long\n```\nlabel]: attachment:pic.png\n```"
        let titled = "[id]: #anchor\n\"title `\"\n![x](attachment:pic.png)\n` end"
        for (index, markdown) in [literal, titled].enumerated() {
            let source = root.appendingPathComponent("book\(index).ipynb")
            let json: [String: Any] = ["nbformat": 4, "nbformat_minor": 5, "metadata": [:], "cells": [
                ["cell_type": "markdown", "metadata": [:], "source": markdown,
                 "attachments": ["pic.png": ["image/png": try png.base64EncodedString()]]]
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
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), try png)
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
        for title in ["'title `\ncontinued'", "(title `\ncontinued)"] {
            let source = "[id]: #anchor\n\(title)\n![x](attachment:pic.png)\n` end"
            XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: source, from: "attachment:pic.png", to: "images/p.png"),
                source.replacingOccurrences(of: "![x](attachment:pic.png)", with: "![x](images/p.png)"))
        }
    }

    func testCorruptPNGPixelPayloadIsRejectedThroughAllResourcePaths() throws {
        // Gültige Chunk-Prüfsummen kaschieren hier absichtlich einen defekten Pixelstrom.
        let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAADklEQVRub3QtdmFsaWQtemxpYlp0dn0AAAAASUVORK5CYII="))
        try bytes.write(to: root.appendingPathComponent("broken.png"))
        for index in 0..<3 {
            let work = root.appendingPathComponent("broken-work\(index)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let target = index == 0 ? "data:image/png;base64,\(bytes.base64EncodedString())" : index == 1 ? "broken.png" : "https://example.invalid/broken.png"
            let resources: [String: HTMLImageSourceResolver.Subresource] = index == 2 ? [target: .init(data: bytes, mimeType: "image/png")] : [:]
            let result = try HTMLImageSourceResolver.resolve(html: "<img alt=\"ALTTOKEN\" src=\"\(target)\">", baseDirectory: root, baseURL: nil, subresources: resources, workDirectory: work)
            XCTAssertEqual(result.html, "ALTTOKEN")
            XCTAssertEqual(result.missingImagesDropped, 1)
            XCTAssertTrue((try FileManager.default.subpathsOfDirectory(atPath: work.path)).allSatisfy { !$0.hasSuffix(".png") })
        }
    }

    func testTruncatedRasterImagesKeepAltTextAndReportLoss() throws {
        for (index, bytes) in [Data(try png.prefix(16)), try png].enumerated() {
            let source = root.appendingPathComponent("image\(index).html")
            let html = Data("<p>BEFORETOKEN</p><img alt=\"ALTTOKEN\" src=\"data:image/png;base64,\(bytes.base64EncodedString())\"><p>AFTERTOKEN</p>".utf8)
            try html.write(to: source)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
                destination: .directory(root.appendingPathComponent("image-output\(index)"))))
            let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for token in ["BEFORETOKEN", "ALTTOKEN", "AFTERTOKEN"] {
                XCTAssertEqual(output.components(separatedBy: token).count - 1, 1)
            }
            if index == 0 {
                XCTAssertTrue(result.assets.isEmpty)
                XCTAssertTrue(result.diagnostics.contains { $0.code == "html.missingImagesDropped" }, "\(result.diagnostics)")
            } else {
                let asset = try XCTUnwrap(result.assets.first)
                XCTAssertEqual(try Data(contentsOf: asset), bytes)
                let image = try XCTUnwrap(CGImageSourceCreateWithURL(asset as CFURL, nil))
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(image, 0, nil))
            }
            XCTAssertEqual(try Data(contentsOf: source), html)
        }
    }

    func testTruncatedLocalAndArchivedRasterSourcesAreNotPublished() throws {
        let bytes = Data(try png.prefix(16))
        let local = root.appendingPathComponent("local.png")
        try bytes.write(to: local)
        for archived in [false, true] {
            let work = root.appendingPathComponent(archived ? "archive-work" : "local-work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let target = archived ? "https://example.invalid/picture.png" : "local.png"
            let resources: [String: HTMLImageSourceResolver.Subresource] = archived
                ? [target: .init(data: bytes, mimeType: "image/png")] : [:]
            let result = try HTMLImageSourceResolver.resolve(html: "<img alt=\"ALTTOKEN\" src=\"\(target)\">",
                baseDirectory: root, baseURL: nil, subresources: resources, workDirectory: work)
            XCTAssertEqual(result.html, "ALTTOKEN")
            XCTAssertEqual(result.missingImagesDropped, 1)
            let files = FileManager.default.enumerator(at: work, includingPropertiesForKeys: [.isRegularFileKey])!
            XCTAssertTrue(files.allObjects.compactMap { $0 as? URL }.allSatisfy {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true
            })
        }
        XCTAssertEqual(try Data(contentsOf: local), bytes)
    }

    func testODSIntermediateEmptyRowsShareTheWorkbookBudget() throws {
        let sheet = "<table:table table:name=\"S\"><table:table-row table:number-rows-repeated=\"900000\"><table:table-cell/></table:table-row><table:table-row><table:table-cell office:value-type=\"string\"><text:p>VALUE</text:p></table:table-cell></table:table-row></table:table>"
        let xml = "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:spreadsheet>\(String(repeating: sheet, count: 12))</office:spreadsheet></office:body></office:document-content>"
        let source = root.appendingPathComponent("budget.ods")
        let bytes = try ZIPFixtureBuilder.odsPackage(contentXML: xml)
        try bytes.write(to: source)
        XCTAssertThrowsError(try DocumentConverter().inspect(source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cell budget"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let small = xml.replacingOccurrences(of: "900000", with: "2")
        let workbook = try ODSWorkbookParser.parse(Data(small.utf8))
        XCTAssertEqual(workbook.sheets.count, 12)
        for sheet in workbook.sheets {
            XCTAssertEqual(sheet.rows.count, 3)
            XCTAssertTrue(sheet.rows[0].isEmpty && sheet.rows[1].isEmpty)
            XCTAssertEqual(sheet.rows[2].map(\.displayText), ["VALUE"])
        }
    }
}
