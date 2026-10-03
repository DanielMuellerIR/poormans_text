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

    func testODSAnnotationPreservesSurroundingCellTextAndNamespaceAttributes() throws {
        let xml = """
        <o:document-content xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
         xmlns:t="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
         xmlns:x="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:other="urn:extension">
        <o:body><o:spreadsheet><t:table other:name="Wrong" t:name="Correct"><t:table-row other:number-rows-repeated="8" t:number-rows-repeated="1">
        <t:table-cell other:value-type="boolean" o:value-type="string" other:number-columns-repeated="5" t:number-columns-repeated="1">
        <x:p>before<o:annotation><x:p>NOTE</x:p></o:annotation>after<x:s other:c="1" x:c="20"/>end</x:p><x:p>next</x:p>
        </t:table-cell><t:table-cell o:value-type="float" other:value="999" o:value="42" t:formula="of:=6*7" other:formula="wrong"/>
        </t:table-row></t:table></o:spreadsheet></o:body></o:document-content>
        """
        let workbook = try ODSWorkbookParser.parse(Data(xml.utf8))
        XCTAssertEqual(workbook.sheets.map(\.name), ["Correct"])
        XCTAssertEqual(workbook.sheets[0].rows.count, 1)
        XCTAssertEqual(workbook.sheets[0].rows[0].count, 2)
        XCTAssertEqual(workbook.sheets[0].rows[0][0].displayText, "beforeafter" + String(repeating: " ", count: 20) + "end\nnext")
        XCTAssertEqual(workbook.sheets[0].rows[0][1].displayText, "42")
        XCTAssertEqual(workbook.sheets[0].rows[0][1].formula, "of:=6*7")
        XCTAssertTrue(workbook.hasUnsupportedObjects)
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
        for (index, source) in ["![image](attachment:pic.png)", "![image][id]\n\n[id]: attachment:pic.png", "> ![image][id]\n>\n> [id]: attachment:pic.png", "![image][id]\n\n[id]:\n  attachment:pic.png", "![x][id]\n\n[id]: attachment:pic.png \"first\nsecond\"", "![x][long label]\n\n[long\nlabel]: attachment:pic.png", #"![x](attachment:a\(b\).png)"#, "![x](attachment:a&lpar;b&rpar;.png)", (0..<4_097).map { "[x](missing\($0).png" }.joined(separator: "\n") + "\n\n![image](attachment:pic.png)"].enumerated() {
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
