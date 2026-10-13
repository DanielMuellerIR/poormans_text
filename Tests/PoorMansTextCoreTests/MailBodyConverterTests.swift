import Foundation
import XCTest
@testable import PoorMansTextCore

final class MailBodyConverterTests: XCTestCase {
    func testRealMailFixtureKeepsBodyAttachmentsAndSourceBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.eml")
        let work = root.appendingPathComponent("work")
        let output = root.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let attachmentBytes = Data([0, 255, 1, 2, 13, 10])
        let mail = """
        From: test@example.invalid
        Subject: Body fixture
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/html; charset=utf-8

        <h1>MAIL_BODY_MARKER</h1><p>Grüße <strong>important</strong></p><img src="https://example.invalid/tracker" alt="remote"><img src="../private.png" alt="unavailable"><script>DO_NOT_RENDER</script>
        --m
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="../../escape.bin"
        Content-Transfer-Encoding: base64

        \(attachmentBytes.base64EncodedString())
        --m--
        """
        let original = Data(mail.utf8)
        try original.write(to: source)
        let read = try VerifiedFileStaging.contents(of: source, maximumBytes: MIMEMessage.maximumSourceBytes, describedAs: "mail fixture")
        let part = try MIMEMessage.read(read)
        let context = AdapterConversionContext(inputURL: source, format: InputFormat(rawValue: "eml"),
            workDirectory: work, stagedOutputDirectory: output, options: ConversionOptions())
        let result = try MailBodyConverter.convert(part, context: context)
        let markdown = try String(contentsOf: output.appendingPathComponent(result.markdownRelativePath), encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "MAIL_BODY_MARKER").count - 1, 1)
        XCTAssertTrue(markdown.contains("Grüße"))
        XCTAssertTrue(markdown.contains("important"))
        XCTAssertFalse(markdown.contains("DO_NOT_RENDER"))
        XCTAssertFalse(markdown.contains("![remote]"))
        XCTAssertFalse(markdown.contains("../private.png"))
        XCTAssertEqual(result.assetRelativePaths.count, 1)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(result.assetRelativePaths[0])), attachmentBytes)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.bin").path))
        XCTAssertTrue(result.warnings.contains { $0.code == "html.remoteImagesKeptAsLinks" })
        XCTAssertTrue(result.warnings.contains { $0.code == "html.missingImagesDropped" })
    }

    func testPlainBodyCannotCreateHTMLOrMarkdownStructure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let output = root.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let text = "# literal heading\n<script>VISIBLE_LITERAL</script>\n![image](file:///private.png)\n- literal\n____\nweiter\n\n    *INDENTED*\n    <tag>"
        let part = try MIMEMessage.read(Data(("Subject: plain\nContent-Type: text/plain; charset=utf-8\n\n" + text).utf8))
        let context = AdapterConversionContext(inputURL: root.appendingPathComponent("plain.eml"), format: InputFormat(rawValue: "eml"),
            workDirectory: work, stagedOutputDirectory: output, options: ConversionOptions())
        let result = try MailBodyConverter.convert(part, context: context)
        let markdown = try String(contentsOf: output.appendingPathComponent(result.markdownRelativePath), encoding: .utf8)
        XCTAssertTrue(result.assetRelativePaths.isEmpty)
        let blocks = try parsedBlocks(output.appendingPathComponent(result.markdownRelativePath), work: work)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?["t"] as? String, "CodeBlock")
        let content = try XCTUnwrap(blocks.first?["c"] as? [Any])
        XCTAssertEqual(content.last as? String, text)
        XCTAssertTrue(markdown.contains("VISIBLE_LITERAL"))
    }

    func testPlainBodyKeepsWhitespaceAndFenceTextBesideHTMLAndAttachments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("literal.eml")
        let text = "\n  two spaces\n\ttab\ninside  spaces  \n```\n``````\n~~~\n# literal\n![not an image](attachments/file.bin)\n<tag>&copy;</tag>\n\n"
        let attachment = Data([0, 255, 13, 10])
        let mail = """
        From: sender@example.invalid
        Subject: Literal whitespace
        Content-Type: multipart/mixed; boundary=parts

        --parts
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        \(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8).base64EncodedString())
        --parts
        Content-Type: text/html; charset=utf-8

        <p>HTML_BODY_MARKER</p>
        --parts
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename=file.bin
        Content-Transfer-Encoding: base64

        \(attachment.base64EncodedString())
        --parts--
        """
        let original = Data(mail.utf8)
        try original.write(to: source)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let outputName = layout == .textbundle ? "literal.textbundle" : "literal-markdown"
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
                destination: .directory(root.appendingPathComponent(outputName)),
                options: ConversionOptions(outputLayout: layout)))
            let blocks = try parsedBlocks(result.markdownFile, work: root)
            let code = blocks.filter { $0["t"] as? String == "CodeBlock" }
            XCTAssertEqual(code.count, 1)
            let content = try XCTUnwrap(code.first?["c"] as? [Any])
            XCTAssertEqual(content.last as? String, text)
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(markdown.components(separatedBy: "HTML_BODY_MARKER").count - 1, 1)
            XCTAssertTrue(blocks.contains { $0["t"] as? String == "Table" })
            XCTAssertTrue(blocks.contains { $0["t"] as? String == "BulletList" })
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: result.assets[0]), attachment)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    private func parsedBlocks(_ markdown: URL, work: URL) throws -> [[String: Any]] {
        let jsonURL = work.appendingPathComponent(UUID().uuidString + ".json")
        // Der Plaintext-Writer fügt bei Codeblöcken eigene Einrückung hinzu.
        // Die Lesersicht prüft stattdessen den vollständigen unveränderten Körper.
        let roundtrip = try ProcessRunner.run(executable: PandocTool.resolve(nil),
            arguments: ["--sandbox", "--preserve-tabs", "--from=gfm", "--to=json", "--output", jsonURL.path, markdown.path],
            currentDirectory: work, timeout: 30)
        XCTAssertEqual(roundtrip.status, 0)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        return try XCTUnwrap(document["blocks"] as? [[String: Any]])
    }

    func testNestedMailLayoutTablesKeepEveryCellText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let output = root.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let html = "<table><tr><td><p>FIRST_CELL</p><table><tr><td><p>INNER_CELL</p></td><td><p>SECOND_INNER</p></td></tr></table></td><td>LAST_CELL</td></tr></table>"
        let part = try MIMEMessage.read(Data(("Subject: layout\nContent-Type: text/html\n\n" + html).utf8))
        let context = AdapterConversionContext(inputURL: root.appendingPathComponent("layout.eml"), format: .eml,
            workDirectory: work, stagedOutputDirectory: output, options: ConversionOptions())
        let result = try MailBodyConverter.convert(part, context: context)
        let markdown = try String(contentsOf: output.appendingPathComponent(result.markdownRelativePath), encoding: .utf8)
        for marker in ["FIRST_CELL", "INNER_CELL", "SECOND_INNER", "LAST_CELL"] {
            XCTAssertEqual(markdown.components(separatedBy: marker).count - 1, 1)
        }
        XCTAssertTrue(result.warnings.contains(.htmlStructureSimplified))
    }
}
