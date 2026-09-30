import Foundation
import XCTest
@testable import PoorMansTextCore

final class MailContentTests: XCTestCase {
    func testAlternativeSelectsOneBodyAndMixedPreservesAttachmentBytes() throws {
        let source = """
        Subject: Selection
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: multipart/alternative; boundary=a

        --a
        Content-Type: text/plain

        plain duplicate
        --a
        Content-Type: text/html

        <p>chosen body</p>
        --a--
        --m
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="../../escape.bin"
        Content-Transfer-Encoding: base64

        AP8BAg==
        --m--
        """
        let selected = try MailContent.select(MIMEMessage.read(Data(source.utf8)))
        XCTAssertEqual(selected.bodies.count, 1)
        XCTAssertEqual(selected.bodies[0].text, "<p>chosen body</p>")
        XCTAssertTrue(selected.bodies[0].isHTML)
        XCTAssertEqual(selected.attachments.count, 1)
        XCTAssertEqual(selected.attachments[0].data, Data([0, 255, 1, 2]))
    }

    func testRelatedRootCanFollowInlineResource() throws {
        let source = """
        Content-Type: multipart/related; boundary=r; start="<body>"

        --r
        Content-Type: image/png
        Content-ID: <image>
        Content-Transfer-Encoding: base64

        AQID
        --r
        Content-Type: text/html
        Content-ID: <body>

        <p>body<img src="cid:image"></p>
        --r--
        """
        let selected = try MailContent.select(MIMEMessage.read(Data(source.utf8)))
        XCTAssertEqual(selected.bodies.count, 1)
        XCTAssertEqual(selected.attachments.count, 1)
        XCTAssertEqual(selected.attachments[0].contentID, "image")
        XCTAssertEqual(selected.attachments[0].data, Data([1, 2, 3]))
    }

    func testAttachedTextIsNeverUsedAsBody() throws {
        let source = "Content-Type: text/plain\nContent-Disposition: attachment; filename=test.txt\n\nattached"
        let selected = try MailContent.select(MIMEMessage.read(Data(source.utf8)))
        XCTAssertTrue(selected.bodies.isEmpty)
        XCTAssertEqual(selected.attachments[0].data, Data("attached".utf8))
    }

    func testNamesCannotProducePathsOrCollide() {
        let names = ["../escape", "/etc/passwd", "..\\escape", "\0\r\nname", ".", "..", "", "a:stream", "💌.pdf", "CON", "a/b"]
        var stored = Set<String>()
        for (index, name) in names.enumerated() {
            let safe = MailContent.storedName(name, index: index + 1)
            XCTAssertFalse(safe.contains("/"))
            XCTAssertFalse(safe.contains("\\"))
            XCTAssertEqual(NSString(string: safe).pathComponents.count, 1)
            XCTAssertTrue(stored.insert(safe).inserted)
        }
    }

    func testEmbeddedMailIsPreservedAsMailAttachment() throws {
        let nested = "Subject: Embedded\r\n\r\ninner body\r\n"
        let source = "Content-Type: message/rfc822\r\n\r\n" + nested
        let selected = try MailContent.select(MIMEMessage.read(Data(source.utf8)))
        XCTAssertTrue(selected.bodies.isEmpty)
        XCTAssertEqual(selected.attachments[0].name, "message.eml")
        XCTAssertEqual(selected.attachments[0].data, Data(nested.utf8))
        XCTAssertEqual(selected.warnings.first?.code, "mail.partSavedAsAttachment")
    }

    func testAttachmentStagingPreservesBytesInsideOwnDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0, 255, 13, 10, 1])
        let attachments = ["../../escape.bin", "/tmp/escape.bin", "same.bin", "same.bin"].map {
            MailContent.Attachment(name: $0, mediaType: "application/octet-stream", data: bytes, contentID: nil, contentLocation: nil)
        }
        let saved = try MailContent.stageAttachments(attachments, in: root)
        XCTAssertEqual(saved.count, 4)
        XCTAssertEqual(Set(saved.map(\.relativePath)).count, 4)
        for file in saved {
            let url = root.appendingPathComponent(file.relativePath)
            XCTAssertEqual(url.deletingLastPathComponent().path, root.appendingPathComponent("attachments").path)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["attachments"])
        XCTAssertThrowsError(try MailContent.stageAttachments(attachments, in: root))
        for file in saved { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file.relativePath)), bytes) }
    }

    func testAttachmentDirectorySymlinkIsRejectedBeforeWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("attachments"), withDestinationURL: outside)
        let attachment = MailContent.Attachment(name: "file.bin", mediaType: "application/octet-stream", data: Data([1]), contentID: nil, contentLocation: nil)
        XCTAssertThrowsError(try MailContent.stageAttachments([attachment], in: output))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testUnreadableUnusedAlternativeDoesNotHideSupportedBody() throws {
        let source = "Content-Type: multipart/alternative; boundary=x\n\n--x\nContent-Type: text/plain; charset=unknown\n\nunknown\n--x\nContent-Type: text/html\n\n<p>chosen</p>\n--x--"
        let result = try MailContent.select(MIMEMessage.read(Data(source.utf8)))
        XCTAssertEqual(result.bodies.count, 1)
        XCTAssertEqual(result.bodies[0].text, "<p>chosen</p>")
        XCTAssertEqual(result.warnings.map(\.code), ["mail.alternativeUnreadable"])
    }

    func testDuplicateResourceIdentifierIsRejected() {
        let attachment = MailContent.Attachment(name: "image.png", mediaType: "image/png", data: Data([1]), contentID: "same", contentLocation: nil)
        XCTAssertThrowsError(try MailContent.subresources([attachment, attachment]))
    }

    func testDigestDefaultsToEmbeddedMailInsteadOfDroppingItsHeaders() throws {
        let nested = "Subject: inner\nFrom: sender@example.invalid\n\ninner body"
        let source = "Content-Type: multipart/digest; boundary=d\n\n--d\n\n" + nested + "\n--d--"
        let result = try MailContent.select(MIMEMessage.read(Data(source.utf8)))
        XCTAssertTrue(result.bodies.isEmpty)
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.attachments[0].data, Data(nested.utf8))
    }

    func testCIDImageReferencesUseVerifiedEmbeddedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg=="))
        let attachment = MailContent.Attachment(name: "../../image.html", mediaType: "image/png", data: png,
                                               contentID: "image@example.invalid", contentLocation: nil)
        let resources = try MailContent.subresources([attachment])
        let html = "<img src=\"CID:image%40example.invalid\" alt=\"Inline\"><img src=\"cid:missing\" alt=\"Missing\"><img src=\"https://example.invalid/tracker\" alt=\"Remote\">"
        let resolution = try HTMLImageSourceResolver.resolve(html: html, baseDirectory: nil, baseURL: nil,
                                                              subresources: resources, workDirectory: root)
        XCTAssertEqual(resolution.missingImagesDropped, 1)
        XCTAssertEqual(resolution.remoteImagesKeptAsLinks, 1)
        let images = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("external"), includingPropertiesForKeys: nil)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: images[0]), png)
        XCTAssertFalse(resolution.html.contains("<img src=\"https:"))
        XCTAssertFalse(resolution.html.contains("<img src=\"cid:"))
    }

    func testAttachedMultipartKeepsCompleteOriginalMIMEEntity() throws {
        let attached = "Content-Type: multipart/mixed; boundary=a\nContent-Disposition: attachment; filename=nested.mime\n\n--a\nContent-Type: text/plain\n\ninner text\n--a--"
        let source = "Content-Type: multipart/mixed; boundary=m\n\n--m\nContent-Type: text/plain\n\nouter body\n--m\n" + attached + "\n--m--"
        let selection = try MailContent.select(MIMEMessage.read(Data(source.utf8)))
        XCTAssertEqual(selection.bodies.map(\.text), ["outer body"])
        XCTAssertEqual(selection.attachments.count, 1)
        XCTAssertEqual(selection.attachments[0].data, Data(attached.utf8))
        XCTAssertEqual(selection.attachments[0].name, "nested.mime")
    }
}
