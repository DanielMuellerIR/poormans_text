import Foundation
import PDFKit
import XCTest
@testable import PoorMansTextCore

final class ReviewOctoberTests: XCTestCase {
    func testNamedRelatedRootAndUndecodableResource() throws {
        for start in ["", "; start=\"<root>\""] {
            let source = """
            Content-Type: multipart/related; boundary=x\(start)

            --x
            Content-Type: text/html
            Content-ID: <root>
            Content-Disposition: inline; filename=body.html

            <p>Readable body</p>
            --x
            Content-Type: text/plain; charset=unknown
            Content-ID: <resource>

            Resource bytes
            --x--
            """
            let selection = try MailContent.select(MIMEMessage.read(Data(source.utf8)))
            XCTAssertEqual(selection.bodies.map(\.text), ["<p>Readable body</p>"])
            XCTAssertEqual(selection.attachments.count, 1)
            XCTAssertEqual(String(decoding: selection.attachments[0].data, as: UTF8.self), "Resource bytes")
        }
    }

    func testEncryptedSMIMEBodyRejectedButForeignAttachmentPreserved() throws {
        for type in ["application/pkcs7-mime", "application/x-pkcs7-mime"] {
            let body = "Content-Type: \(type); smime-type=enveloped-data\n\nopaque"
            XCTAssertThrowsError(try MailContent.select(MIMEMessage.read(Data(body.utf8))))
            let attached = "Content-Disposition: attachment; filename=foreign.p7m\n" + body
            let selection = try MailContent.select(MIMEMessage.read(Data(attached.utf8)))
            XCTAssertEqual(selection.attachments.first?.data, Data("opaque".utf8))
        }
    }

    func testCharsetAttributesCannotBeSpoofedByDescriptions() throws {
        for decoy in ["name=\"description\" content=\"charset=windows-1251\"", "data-charset=\"windows-1251\""] {
            let html = "<meta \(decoy)><meta charset=\"iso-8859-1\"><p>Grüße café</p>"
            let data = try XCTUnwrap(html.data(using: .windowsCP1252))
            XCTAssertEqual(PandocTextAdapter.declaredCharset(in: data), "iso-8859-1")
        }
        XCTAssertEqual(PandocTextAdapter.declaredCharset(in: Data("<meta http-equiv='Content-Type' content='text/html; charset=windows-1252'>".utf8)), "windows-1252")
    }

    func testReferenceTargetsAreSharedByObservationAndReplacement() throws {
        let markdown = "![image][id]\n\n[id]: attachment:pic.png \"title\"\n\n```\n[example]: ignored.png\n```"
        let candidates = try MarkdownLinkTargetRewriter.resourceCandidates(in: markdown, maximum: 10, checking: {})
        XCTAssertEqual(candidates, ["attachment:pic.png"])
        let rewritten = MarkdownLinkTargetRewriter.replacing(in: markdown, mapping: ["attachment:pic.png": "images/image01.png"])
        XCTAssertTrue(rewritten.contains("[id]: images/image01.png \"title\""), rewritten)
        XCTAssertTrue(rewritten.contains("[example]: ignored.png"))
    }

    func testLiteralPDFRectanglesAndLineOrderProduceSameCompleteGrid() throws {
        let ascending = [400,420,440,460].map { "40 \($0) m 240 \($0) l S" }.joined(separator: "\n")
        let descending = [460,440,420,400].map { "40 \($0) m 240 \($0) l S" }.joined(separator: "\n")
        let vertical = [40,140,240].map { "\($0) 400 m \($0) 460 l S" }.joined(separator: "\n")
        let rectangles = [400,420,440].flatMap { y in [40,140].map { x in "\(x) \(y) 100 20 re S" }}.joined(separator: "\n")
        for content in [ascending + "\n" + vertical, descending + "\n" + vertical, rectangles] {
            let page = try XCTUnwrap(PDFDocument(data: pdf(content))?.page(at: 0))
            let grids = PDFTableGeometry.grids(on: page, textHeight: 12)
            XCTAssertEqual(grids.count, 1)
            XCTAssertEqual(grids.first?.rows.count, 4)
            XCTAssertEqual(grids.first?.columns.count, 3)
        }
    }

    func testNotebookReferenceAttachmentReachesRealConversion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
        for (index, source) in ["![image](attachment:pic.png)", "![image][id]\n\n[id]: attachment:pic.png"].enumerated() {
            let notebook: [String: Any] = ["nbformat": 4, "nbformat_minor": 5, "metadata": [:], "cells": [
                ["cell_type": "markdown", "metadata": [:], "source": source,
                 "attachments": ["pic.png": ["image/png": png.base64EncodedString()]]]
            ]]
            let input = root.appendingPathComponent("cell\(index).ipynb")
            try JSONSerialization.data(withJSONObject: notebook).write(to: input)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: input))
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertFalse(markdown.contains("attachment:"), markdown)
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: result.assets[0]), png)
            XCTAssertTrue(result.warnings.isEmpty, result.warnings.joined(separator: "\n"))
        }
    }

    func testTextbundleUsesOneMappingAndHonorsCancellation() throws {
        for cancel in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let markdown = "![a](images/first.png) ![b](images/second%20photo.png)"
            try Data(markdown.utf8).write(to: root.appendingPathComponent("body.md"))
            for name in ["first.png", "second photo.png"] { try Data([1]).write(to: root.appendingPathComponent("images/" + name)) }
            let token = ConversionCancellationToken()
            if cancel { token.cancel() }
            let context = ConversionExecution.Context(cancellation: token, progress: nil, processTimeout: nil)
            let operation = {
                try ConversionExecution.$current.withValue(context) {
                    try ConversionPostprocessor.applyTextbundleLayout(in: root, markdownRelativePath: "body.md",
                        assetRelativePaths: ["images/first.png", "images/second photo.png"], fileManager: .default)
                }
            }
            if cancel {
                XCTAssertThrowsError(try operation())
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("text.md").path))
            } else {
                _ = try operation()
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("text.md"), encoding: .utf8),
                               "![a](assets/first.png) ![b](assets/second%20photo.png)")
            }
        }
    }

    private func pdf(_ content: String) -> Data {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>", "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"]
        var output = "%PDF-1.4\n", offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(output.utf8.count)
            output += "\(index+1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = output.utf8.count
        output += "xref\n0 5\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { output += String(format: "%010d 00000 n \n", offset) }
        output += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(output.utf8)
    }
}
