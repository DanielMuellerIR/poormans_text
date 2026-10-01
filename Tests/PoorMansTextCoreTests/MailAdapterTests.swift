import Foundation
import XCTest
@testable import PoorMansTextCore

final class MailAdapterTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PoorMansMailAdapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func source(_ text: String, named name: String = "fixture.eml", emlx: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        var bytes = Data(text.utf8)
        if emlx { bytes = Data("\(bytes.count)\n".utf8) + bytes + Data("\n<plist/>".utf8) }
        try bytes.write(to: url)
        return url
    }

    func testEMLAndAppleMailHaveIdenticalContentAndVisibleHeaders() throws {
        let mail = "From: sender@example.invalid\r\nTo: receiver@example.invalid\r\nSubject: =?utf-8?Q?Gr=C3=BC=C3=9Fe?=\r\nDate: Wed, 30 Sep 2026 10:30:00 +0200\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBody marker Grüße"
        let eml = try source(mail, named: "plain.eml")
        let emlx = try source(mail, named: "apple.emlx", emlx: true)
        let original = try Data(contentsOf: emlx)
        let a = try DocumentConverter().convert(ConversionRequest(inputURL: eml))
        let b = try DocumentConverter().convert(ConversionRequest(inputURL: emlx))
        let markdown = try String(contentsOf: a.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown, try String(contentsOf: b.markdownFile, encoding: .utf8))
        XCTAssertTrue(markdown.hasPrefix("| Header | Value |\n"))
        XCTAssertFalse(markdown.hasPrefix("---"))
        XCTAssertTrue(markdown.contains("| subject | Grüße |"))
        XCTAssertTrue(markdown.contains("Body marker Grüße"))
        XCTAssertEqual(a.format, .eml)
        XCTAssertEqual(b.format, .eml)
        XCTAssertEqual(a.metadata.title, "Grüße")
        XCTAssertEqual(a.metadata.created.map(DocumentMetadata.iso8601), "2026-09-30T08:30:00Z")
        XCTAssertEqual(try Data(contentsOf: emlx), original)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: emlx)))
        XCTAssertEqual(markdown, try String(contentsOf: a.markdownFile, encoding: .utf8))
    }

    func testHeaderCannotInjectTableRowsAndFrontmatterIsOptIn() throws {
        let mail = "From: sender@example.invalid\nSubject: =?utf-8?Q?hello=0A=7Cevil=7C=0A=23title?=\nContent-Type: text/plain\n\nbody"
        let url = try source(mail)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: url, options: ConversionOptions(frontmatter: true)))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertTrue(markdown.contains("| subject | hello \\|evil\\| #title |"))
        XCTAssertFalse(markdown.contains("\n|evil|\n"))
        XCTAssertTrue(markdown.contains("\\n"))
    }

    func testTextbundleMovesAttachmentsAndRewritesTheirLinks() throws {
        let mail = "Content-Type: application/octet-stream\nContent-Disposition: attachment; filename=../../escape.bin\nContent-Transfer-Encoding: base64\n\nAAH/"
        let url = try source(mail)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: url, options: ConversionOptions(outputLayout: .textbundle)))
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertEqual(try Data(contentsOf: result.assets[0]), Data([0, 1, 255]))
        XCTAssertEqual(result.assets[0].deletingLastPathComponent().lastPathComponent, "assets")
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("](assets/"))
        XCTAssertFalse(markdown.contains("](attachments/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.outputDirectory.appendingPathComponent("attachments").path))
    }

    func testMailDetectionPrecedesHTMLAndRecognizesContentWithoutExtension() throws {
        let mail = "From: sender@example.invalid\nSubject: HTML mail\nContent-Type: text/html\n\n<html><body>message</body></html>"
        let url = try source(mail, named: "mail.data")
        XCTAssertEqual(try DocumentConverter().detectFormat(at: url), .eml)
        let malformed = try source("invalid header\n\n<html><body>not mail</body></html>", named: "bad.eml")
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: malformed)) { error in
            guard case ConversionError.invalidInput(_, .eml, _) = error else { return XCTFail("Expected invalid EML") }
        }
    }

    func testMalformedMIMELeavesNoOutputAndSourceUnchanged() throws {
        let url = try source("From: sender@example.invalid\nContent-Type: multipart/mixed; boundary=x\n\n--x\n\nbody")
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: url)))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentConverter.defaultOutputDirectory(for: url).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["fixture.eml"])
    }

    func testAppleMailPaddedByteCountIsRecognized() throws {
        let message = Data("From: sender@example.invalid\nSubject: padded count\n\nbody".utf8)
        let url = root.appendingPathComponent("padded.emlx")
        let line = String(message.count).padding(toLength: 20, withPad: " ", startingAt: 0) + "\n"
        try (Data(line.utf8) + message).write(to: url)
        XCTAssertEqual(try DocumentConverter().detectFormat(at: url), .eml)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: url))
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("body"))
    }

    func testPrivateCorpusAgainstIndependentDecoder() throws {
        guard let path = ProcessInfo.processInfo.environment["POORMANS_TEXT_MAIL_CORPUS"] else {
            throw XCTSkip("No private mail corpus supplied")
        }
        struct Case: Decodable {
            let id: String
            let words: [String: Int]
            let attachments: [String?]
        }
        let corpus = URL(fileURLWithPath: path)
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: corpus.appendingPathComponent("oracle.json")))
        let expression = try NSRegularExpression(pattern: #"[\p{L}\p{N}_]+"#)
        var errors = [String: String]()
        var observed = [String: [String: Int]]()
        defer {
            if let data = try? JSONEncoder().encode(errors) { try? data.write(to: corpus.appendingPathComponent("private-errors.json")) }
            if let data = try? JSONEncoder().encode(observed) { try? data.write(to: corpus.appendingPathComponent("private-observed.json")) }
        }
        for item in cases {
            let input = corpus.appendingPathComponent(item.id + ".emlx")
            let snapshot = try Data(contentsOf: input)
            let output = root.appendingPathComponent(item.id)
            let result: ConversionResult
            do {
                result = try DocumentConverter().convert(ConversionRequest(inputURL: input, destination: .directory(output)), processTimeout: 30)
            } catch {
                errors[item.id] = error.localizedDescription
                // Keine Header, Namen oder Werkzeugdetails aus privaten Testmails ins Testlog übernehmen.
                XCTFail("Private corpus conversion failed in case " + item.id)
                continue
            }
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            let bodyStart = try XCTUnwrap(markdown.range(of: "\n\n"))
            var body = String(markdown[bodyStart.upperBound...])
            if let list = body.range(of: "\n\n## Attachments\n\n", options: .backwards) { body = String(body[..<list.lowerBound]) }
            let bodyURL = root.appendingPathComponent(item.id + "-body.md")
            let textURL = root.appendingPathComponent(item.id + "-body.txt")
            try Data(body.utf8).write(to: bodyURL)
            let run = try ProcessRunner.run(executable: PandocTool.resolve(nil),
                arguments: ["--sandbox", "--from=gfm", "--to=plain", "--output", textURL.path, bodyURL.path], currentDirectory: root, timeout: 30)
            XCTAssertTrue(run.status == 0, "Roundtrip in case " + item.id)
            let text = try String(contentsOf: textURL, encoding: .utf8).precomposedStringWithCanonicalMapping as NSString
            var words = [String: Int]()
            for match in expression.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                words[text.substring(with: match.range), default: 0] += 1
            }
            let missing = item.words.filter { words[$0.key, default: 0] < $0.value }.count
            observed[item.id] = words
            XCTAssertTrue(missing == 0, "Missing body token counts in case " + item.id + ": " + String(missing))
            let attachments = result.assets.filter { $0.deletingLastPathComponent().lastPathComponent == "attachments" }
            XCTAssertTrue(attachments.count == item.attachments.count, "Attachment count in case " + item.id)
            for (url, expected) in zip(attachments, item.attachments) {
                if let expected {
                    let bytes = try Data(contentsOf: url)
                    XCTAssertTrue(bytes.base64EncodedString() == expected, "Attachment bytes in case " + item.id)
                }
            }
            XCTAssertTrue(try Data(contentsOf: input) == snapshot, "Source preservation in case " + item.id)
        }
    }
}
