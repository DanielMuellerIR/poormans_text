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
        let text = "# literal heading\n<script>VISIBLE_LITERAL</script>\n![image](file:///private.png)"
        let part = try MIMEMessage.read(Data(("Subject: plain\nContent-Type: text/plain; charset=utf-8\n\n" + text).utf8))
        let context = AdapterConversionContext(inputURL: root.appendingPathComponent("plain.eml"), format: InputFormat(rawValue: "eml"),
            workDirectory: work, stagedOutputDirectory: output, options: ConversionOptions())
        let result = try MailBodyConverter.convert(part, context: context)
        let markdown = try String(contentsOf: output.appendingPathComponent(result.markdownRelativePath), encoding: .utf8)
        XCTAssertTrue(markdown.contains("VISIBLE_LITERAL"))
        XCTAssertFalse(markdown.hasPrefix("# literal heading"))
        XCTAssertFalse(markdown.contains("<script>"))
        XCTAssertTrue(result.assetRelativePaths.isEmpty)
        let plainURL = work.appendingPathComponent("roundtrip.txt")
        let roundtrip = try ProcessRunner.run(executable: PandocTool.resolve(nil),
            arguments: ["--sandbox", "--from=gfm", "--to=plain", "--output", plainURL.path, output.appendingPathComponent(result.markdownRelativePath).path],
            currentDirectory: work, timeout: 30)
        XCTAssertEqual(roundtrip.status, 0)
        XCTAssertEqual(try String(contentsOf: plainURL, encoding: .utf8).trimmingCharacters(in: .newlines), text)
    }
}
