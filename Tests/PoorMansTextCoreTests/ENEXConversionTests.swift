import Foundation
import XCTest
@testable import PoorMansTextCore

final class ENEXConversionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTENEX-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func note(_ number: Int, title: String = "Same title", content: String, extra: String = "") -> String {
        "<note><title>" + ENMLConverter.escaped(title) + "</title><content>" + ENMLConverter.escaped(content)
        + "</content><created>20261018T051000Z</created><updated>20261018T061000Z</updated><tag>one</tag><tag>Grüße</tag>"
        + "<note-attributes><author>Author</author><source-url>https://example.test/\(number)</source-url></note-attributes>" + extra + "</note>"
    }
    private func source(_ notes: [String], name: String = "archive.enex") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(("<!DOCTYPE en-export SYSTEM \"http://xml.evernote.com/pub/evernote-export4.dtd\"><en-export>" + notes.joined() + "</en-export>").utf8).write(to: url)
        return url
    }

    func testOrderedCollectionKeepsUnicodeTagsDatesCheckboxesCodeAndSourceHash() throws {
        let first = "<!DOCTYPE en-note SYSTEM \"http://xml.evernote.com/pub/enml2.dtd\"><en-note><p>ENEX_BODY_ONE</p><div><en-todo/>OPEN_TASK</div><div><en-todo checked=\"true\"/>DONE_TASK</div><div style=\"-en-codeblock:true;\"><div>let value = &lt;literal&gt;</div><div>``` code &amp; marker</div></div><p>A&nbsp;B</p></en-note>"
        let url = try source([note(1, content: first), note(2, title: "Grüße 🙂 [Titel]", content: "<en-note><p>ENEX_BODY_TWO</p></en-note>")])
        let original = try Data(contentsOf: url)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let result = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary,
                options: .init(frontmatter: true, outputLayout: layout, conversionReport: true)))
            defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
            XCTAssertEqual(result.format, .enex)
            XCTAssertTrue(result.isCollection)
            XCTAssertEqual(result.documents.map(\.sourceIndex), [1, 2])
            XCTAssertEqual(result.documents.map(\.title), ["Same title", "Grüße 🙂 [Titel]"])
            for (index, document) in result.documents.enumerated() {
                let text = try String(contentsOf: document.markdownFile, encoding: .utf8)
                XCTAssertTrue(text.hasPrefix("---\n"))
                XCTAssertEqual(text.components(separatedBy: index == 0 ? "ENEX_BODY_ONE" : "ENEX_BODY_TWO").count - 1, 1)
                XCTAssertFalse(text.contains(index == 0 ? "ENEX_BODY_TWO" : "ENEX_BODY_ONE"))
                XCTAssertEqual(document.metadata.keywords, ["one", "Grüße"])
                XCTAssertEqual(document.metadata.created.map(DocumentMetadata.iso8601), "2026-10-18T05:10:00Z")
                XCTAssertEqual(document.metadata.modified.map(DocumentMetadata.iso8601), "2026-10-18T06:10:00Z")
                XCTAssertEqual(document.metadata.author, "Author")
                XCTAssertTrue(text.contains("| note-attributes/source-url | https://example.test/\(index + 1) |"))
                if index == 0 {
                    XCTAssertTrue(text.contains("☐OPEN_TASK") || text.contains("☐ OPEN_TASK"))
                    XCTAssertTrue(text.contains("☑DONE_TASK") || text.contains("☑ DONE_TASK"))
                    XCTAssertTrue(text.contains("let value = <literal>"))
                    XCTAssertTrue(text.contains("``` code & marker"))
                    XCTAssertTrue(text.contains("A\u{00A0}B"))
                }
            }
            XCTAssertEqual(result.sourceMappings.compactMap(\.source.note), ["1", "2"])
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
            XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testEncryptedUnsupportedAndResourceContentHaveConcreteDiagnostics() throws {
        let content = "<en-note><p>SAFE_BODY</p><en-crypt hint=\"Hint\" cipher=\"AES\">CIPHER_TEXT_123</en-crypt><unknown data=\"ATTR_MARKER\">UNKNOWN_TEXT</unknown><script>ACTIVE_TEXT</script><en-media type=\"image/png\" hash=\"01234567890123456789012345678901\" alt=\"IMAGE_LABEL\"/><a href=\"evernote:///view/1/s1/missing/missing/\">NOTE_LINK_LABEL</a></en-note>"
        let url = try source([note(1, content: content, extra: "<resource><data encoding=\"base64\">AQID</data><mime>application/octet-stream</mime></resource><custom-field>FIELD_MARKER</custom-field>")])
        let result = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary, options: .init(conversionReport: true)))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let text = try String(contentsOf: result.documents[0].markdownFile, encoding: .utf8).replacingOccurrences(of: "\\_", with: "_")
        for marker in ["SAFE_BODY", "CIPHER_TEXT_123", "UNKNOWN_TEXT", "ACTIVE_TEXT", "ATTR_MARKER", "IMAGE_LABEL", "FIELD_MARKER", "NOTE_LINK_LABEL"] {
            XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, marker)
        }
        XCTAssertTrue(text.contains("hint=\"Hint\""))
        XCTAssertTrue(text.contains("evernote:///view/1/s1/missing/missing/"))
        XCTAssertEqual(result.documents[0].assets.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.documents[0].assets.first)), Data([1, 2, 3]))
        let codes = Set(result.diagnostics.map(\.code))
        XCTAssertTrue(codes.isSuperset(of: ["enex.encryptedContentRetained", "enex.unsupportedElementRetained", "enex.resourceMissing", "enex.internalLinkInvalid", "enex.unknownFieldsRetained"]))
        XCTAssertTrue(result.diagnostics.allSatisfy { $0.location?.note == "1" })
        XCTAssertEqual(result.diagnostics.first { $0.code == "enex.resourceMissing" }?.omittedCount, 1)
    }

    func testTasksKeepStaticStateTitleAndRawSourceFields() throws {
        let tasks = "<task><title>TASK_DONE</title><taskStatus>completed</taskStatus><dueDate>2757600913T000000Z</dueDate><noteLevelID>ID_ONE</noteLevelID></task><task><title>TASK_OPEN</title><taskStatus>open</taskStatus><noteLevelID>ID_TWO</noteLevelID></task>"
        let url = try source([note(1, content: "<en-note>BODY_TASKS</en-note>", extra: tasks)])
        let result = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let text = try String(contentsOf: result.documents[0].markdownFile, encoding: .utf8).replacingOccurrences(of: "\\_", with: "_")
        XCTAssertTrue(text.contains("- [x] TASK_DONE"))
        XCTAssertTrue(text.contains("- [ ] TASK_OPEN"))
        XCTAssertEqual(text.components(separatedBy: "TASK_DONE").count - 1, 1)
        XCTAssertTrue(text.contains("2757600913T000000Z"))
        XCTAssertTrue(text.contains("ID_ONE"))
        XCTAssertTrue(text.contains("ID_TWO"))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "enex.tasksFlattened" })
    }

    func testLateInvalidENMLCancellationAndCollisionPublishNothing() throws {
        let valid = note(1, content: "<en-note>ONE</en-note>")
        let invalid = try source([valid, note(2, content: "<en-note><p>broken</en-note>")], name: "invalid.enex")
        let destination = root.appendingPathComponent("invalid-result")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: invalid, destination: .directory(destination))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let url = try source([valid, note(2, content: "<en-note>TWO</en-note>")])
        let token = ConversionCancellationToken()
        let cancelled = root.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: url, destination: .directory(cancelled)), progress: { value in
            if value.unit == .note && value.completed == 1 { token.cancel() }
        }, cancellation: token)) { if case ConversionError.cancelled = $0 {} else { XCTFail("unexpected error: \($0)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("sentinel")
        try Data("KEEP".utf8).write(to: sentinel)
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: url, destination: .directory(destination))))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "KEEP")
    }

    func testEmptyContentEmptyArchiveDuplicateTitlesAndExtensionlessDetection() throws {
        let empty = try source([])
        let result = try DocumentConverter().convert(.init(inputURL: empty, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        XCTAssertTrue(result.isCollection)
        XCTAssertTrue(result.documents.isEmpty)
        let url = try source([note(1, content: ""), note(2, content: "<en-note/>")], name: "archive.dat")
        XCTAssertEqual(try DocumentConverter().inspect(url).format, .enex)
        let collection = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: collection.outputDirectory) }
        XCTAssertEqual(collection.documents.map(\.title), ["Same title", "Same title"])
        XCTAssertEqual(Set(collection.documents.map(\.markdownFile)).count, 2)
    }

    func testNamespacesExpansionAndSplitUTF8ProbeAreBounded() throws {
        XCTAssertThrowsError(try ENEXReader.read(Data("<en-export xmlns:x=\"urn:unexpected\"><note><title>A</title><content/></note></en-export>".utf8)))
        let oversized = "<en-note><unknown><![CDATA[" + String(repeating: "&", count: 2_000_000) + "]]></unknown></en-note>"
        XCTAssertThrowsError(try ENEXXML.parse(oversized, root: "en-note"))
        var content = "<en-export><note><title>A</title><content>&lt;en-note&gt;"
        content += String(repeating: "x", count: 32_767 - content.utf8.count)
        content += "🙂&lt;/en-note&gt;</content></note></en-export>"
        let url = root.appendingPathComponent("probe.enex")
        try Data(content.utf8).write(to: url)
        XCTAssertEqual(try DocumentConverter().inspect(url).format, .enex)
        let result = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let text = try String(contentsOf: result.documents[0].markdownFile, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "🙂").count - 1, 1)
    }
}
