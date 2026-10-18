import Darwin
import Foundation
import XCTest
@testable import PoorMansTextCore

final class MBOXReaderTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTMBOX-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let envelope = "From sender@example.test Sun Oct 18 06:00:00 2026"
    private func mail(_ number: Int, body: String = "BODY", ending: String = "\n") -> String {
        ["From: Sender <sender@example.test>", "To: receiver@example.test", "Subject: Same title",
         "Message-ID: <duplicate@example.test>", "Date: Sun, 18 Oct 2026 06:00:00 +0000",
         "X-Ordinal: \(number)", "X-Folded: first", " second", "Content-Type: text/plain; charset=utf-8", "", body]
            .joined(separator: ending) + ending
    }
    private func source(_ data: Data, name: String = "mail.mbox") throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    private func archive(_ messages: [String], ending: String = "\n") -> Data {
        Data(messages.map { envelope + ending + $0 + ending }.joined().utf8)
    }

    func testReaderPreservesMessageBytesOrderQuotingAndBothLineEndings() throws {
        for ending in ["\n", "\r\n"] {
            let body = "BODY_ONE\(ending)From ordinary prose\(ending)From sender@example.test said hello\(ending)>From escaped\(ending)>>From already quoted\(ending)\(ending)last"
            let messages = [mail(1, body: body, ending: ending), mail(2, body: "BODY_TWO", ending: ending)]
            let data = archive(messages, ending: ending)
            let url = try source(data, name: ending == "\n" ? "lf.mbox" : "crlf.mbox")
            var actual: [MBOXReader.Message] = []
            try MBOXReader.read(url) { actual.append($0) }
            XCTAssertEqual(actual.map(\.index), [1, 2])
            XCTAssertEqual(actual.map(\.data), messages.map { Data($0.utf8) })
            XCTAssertEqual(actual.map(\.hasQuotedFrom), [true, false])
            XCTAssertEqual(actual.map(\.envelope), [envelope, envelope])
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testChunkBoundariesAndFinalUnterminatedBodyArePreserved() throws {
        let first = mail(1, body: String(repeating: "x", count: 65_520) + "\nEND_ONE")
        let second = mail(2, body: "END_TWO").dropLast()
        let bytes = Data((envelope + "\n" + first + "\n" + envelope + "\n" + second).utf8)
        let url = try source(bytes)
        var messages: [Data] = []
        try MBOXReader.read(url) { messages.append($0.data) }
        XCTAssertEqual(messages, [Data(first.utf8), Data(second.utf8)])
    }

    func testCollectionPreservesAllHeadersDuplicateIDsBodiesAssetsAndSourceHash() throws {
        let bytes = Data([0, 255, 17, 18, 0, 42])
        let multipart = "From: sender@example.test\nSubject: Same title\nMessage-ID: <duplicate@example.test>\nX-Ordinal: 2\nContent-Type: multipart/mixed; boundary=abc123\n\n--abc123\nContent-Type: text/plain; charset=utf-8\n\nBODY_TWO\n--abc123\nContent-Type: application/octet-stream\nContent-Disposition: attachment; filename=same.bin\nContent-Transfer-Encoding: base64\n\n\(bytes.base64EncodedString())\n--abc123--\n"
        let original = archive([mail(1, body: "BODY_ONE\n>From kept"), multipart])
        let url = try source(original)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let result = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary,
                options: .init(frontmatter: true, outputLayout: layout, conversionReport: true)))
            defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
            XCTAssertEqual(result.format, .mbox)
            XCTAssertTrue(result.isCollection)
            XCTAssertEqual(result.documents.map(\.sourceIndex), [1, 2])
            XCTAssertEqual(result.documents.map(\.title), ["Same title", "Same title"])
            for (index, document) in result.documents.enumerated() {
                let markdown = try String(contentsOf: document.markdownFile, encoding: .utf8)
                XCTAssertEqual(markdown.components(separatedBy: index == 0 ? "BODY_ONE" : "BODY_TWO").count - 1, 1)
                XCTAssertFalse(markdown.contains(index == 0 ? "BODY_TWO" : "BODY_ONE"))
                XCTAssertTrue(markdown.contains("| x-ordinal | \(index + 1) |"))
                XCTAssertTrue(markdown.contains("| mbox-envelope | \(envelope) |"))
                XCTAssertTrue(markdown.contains("| message-id | \\<duplicate@example.test\\> |"))
                if index == 0 {
                    XCTAssertTrue(markdown.contains("| x-folded | first second |"))
                    XCTAssertTrue(markdown.contains("| to | receiver@example.test |"))
                    XCTAssertTrue(markdown.contains("| date | Sun, 18 Oct 2026 06:00:00 +0000 |"))
                }
            }
            let attachment = try XCTUnwrap(result.documents[1].assets.first)
            XCTAssertEqual(try Data(contentsOf: attachment), bytes)
            XCTAssertEqual(result.sourceMappings.compactMap(\.source.message), ["1", "2"])
            XCTAssertEqual(result.diagnostics.filter { $0.code == "mbox.fromQuotingRetained" }.map(\.location?.message), ["1"])
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
            XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testLateMalformedMessageAndAmbiguousSeparatorPublishNothing() throws {
        let samples = [
            envelope + "\n" + mail(1) + "\n" + envelope + "\nnot a header\n\nLOST\n\n",
            envelope + "\n" + mail(1, body: "before\n" + envelope + "\nafter"),
            envelope + "\n" + mail(1) + "\n" + envelope + "\nContent-Length: 4\nSubject: second\n\nbody\n\n",
            envelope + "\n" + mail(1) + "\nFrom sender@example.test Sun Feb 31 06:00:00 2026\n" + mail(2),
            envelope + "\n" + mail(1) + "\nFrom sender@example.test unknown timestamp\n" + mail(2)
        ]
        for (index, sample) in samples.enumerated() {
            let url = try source(Data(sample.utf8), name: "bad\(index).mbox")
            let destination = root.appendingPathComponent("rejected\(index)")
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: url, destination: .directory(destination))))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testEmptyArchiveAndEmptyMessageHaveExplicitCompleteResults() throws {
        let empty = try source(Data(), name: "empty.mbox")
        let result = try DocumentConverter().convert(.init(inputURL: empty, destination: .temporary, options: .init(conversionReport: true)))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        XCTAssertTrue(result.isCollection)
        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("No documents."))
        let url = try source(archive([mail(1, body: "")]))
        let one = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: one.outputDirectory) }
        XCTAssertEqual(one.documents.count, 1)
    }

    func testCancellationAfterFirstMessageAndCollisionAreAtomic() throws {
        let original = archive([mail(1, body: "ONE"), mail(2, body: "TWO")])
        let url = try source(original)
        let destination = root.appendingPathComponent("cancelled")
        let token = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: url, destination: .directory(destination)), progress: { progress in
            if progress.unit == .message && progress.completed == 1 { token.cancel() }
        }, cancellation: token)) { if case ConversionError.cancelled = $0 {} else { XCTFail("unexpected error: \($0)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("sentinel")
        try Data("KEEP".utf8).write(to: sentinel)
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: url, destination: .directory(existing))))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "KEEP")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testInvalidKindsBudgetsAndContentLengthAreRejectedWithoutExpansion() throws {
        let preamble = try source(Data(("preamble\n" + envelope + "\n" + mail(1)).utf8), name: "preamble.mbox")
        XCTAssertThrowsError(try DocumentConverter().inspect(preamble))
        let contentLength = try source(archive(["Content-Length: 4\nSubject: test\n\nbody\n"]), name: "length.mbox")
        XCTAssertThrowsError(try DocumentConverter().inspect(contentLength))
        let bareCR = try source(Data((envelope + "\r" + mail(1, ending: "\r")).utf8), name: "cr.mbox")
        XCTAssertThrowsError(try DocumentConverter().inspect(bareCR))
        let line = try source(archive([mail(1, body: String(repeating: "x", count: MBOXReader.maximumLineBytes + 1))]), name: "line.mbox")
        XCTAssertThrowsError(try MBOXReader.read(line) { _ in XCTFail("oversized message was emitted") })
        let sparse = root.appendingPathComponent("large.mbox")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(MBOXReader.maximumArchiveBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try MBOXReader.read(sparse) { _ in XCTFail("oversized archive was emitted") })
        let directory = root.appendingPathComponent("package.mbox")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(mail(1).utf8).write(to: directory.appendingPathComponent("misleading.eml"))
        XCTAssertFalse(InputEnumerator().isSearchableDirectory(directory))
        XCTAssertEqual(try InputEnumerator().enumerate([directory]).map { $0.url.path }, [directory.path])
        XCTAssertThrowsError(try DocumentConverter().inspect(directory))
    }

    func testContentDetectionWorksWithoutExtensionAndRejectsMalformedEnvelope() throws {
        let url = try source(archive([mail(1)]), name: "archive.dat")
        XCTAssertEqual(try DocumentConverter().inspect(url).format, .mbox)
        XCTAssertFalse(MBOXReader.isEnvelope(Data("From sender@example.test Sun Oct 18 25:00:00 2026".utf8)))
        XCTAssertFalse(MBOXReader.isEnvelope(Data("From prose without timestamp".utf8)))
        XCTAssertTrue(MBOXReader.isEnvelope(Data("From MAILER-DAEMON Sun Oct 18 06:00:00 +0200 2026 remote from mailhost".utf8)))
        XCTAssertFalse(MBOXReader.isEnvelope(Data("From sender@example.test Sun Feb 31 06:00:00 2026".utf8)))
        XCTAssertFalse(MBOXReader.isEnvelope(Data("From sender@example.test Sun Oct 18 06:00:00 0000".utf8)))
    }

    func testMessageCountAndMessageByteBudgetsStopTheReader() throws {
        let many = try source(Data(String(repeating: envelope + "\n" + mail(1) + "\n", count: CollectionLimits.maximumDocuments + 1).utf8), name: "many.mbox")
        var count = 0
        XCTAssertThrowsError(try MBOXReader.read(many) { _ in count += 1 })
        XCTAssertEqual(count, CollectionLimits.maximumDocuments)
        let large = root.appendingPathComponent("message-limit.mbox")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: Data((envelope + "\n" + mail(1)).utf8)))
        let handle = try FileHandle(forWritingTo: large)
        try handle.seekToEnd()
        let block = Data((String(repeating: "x", count: 1023) + "\n").utf8)
        for _ in 0..<(MIMEMessage.maximumSourceBytes / block.count + 1) { try handle.write(contentsOf: block) }
        try handle.close()
        XCTAssertThrowsError(try MBOXReader.read(large) { _ in XCTFail("oversized message was emitted") })
    }
}
