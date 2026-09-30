import Foundation
import XCTest
@testable import PoorMansTextCore

final class MSGMessageTests: XCTestCase {
    func testPlainUnicodeAndSafeAttachmentNames() throws {
        let text = "Grüße 日本 😀 <b>literal</b>"
        let bytes = try fixture(text: text, attachment: Data([0, 255, 1, 2]))
        let message = try MSGMessage.read(bytes)
        guard case .text(let actual) = message.body else { return XCTFail("Expected text") }
        XCTAssertEqual(actual, text)
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments[0].name, "../../escape.bin")
        XCTAssertEqual(message.attachments[0].data, Data([0, 255, 1, 2]))
    }

    func testRejectsMissingValuesInvalidCountsAndExternalAttachmentMethods() throws {
        XCTAssertThrowsError(try MSGMessage.read(fixture(text: "body", omitBodyStream: true)))
        XCTAssertThrowsError(try MSGMessage.read(fixture(text: "body", attachment: Data([3]), method: 2)))
        XCTAssertThrowsError(try MSGMessage.read(fixture(text: "body", attachment: Data([3]), wrongCount: true)))
        XCTAssertThrowsError(try MSGMessage.read(Data("not an OLE message".utf8)))
    }

    func testRejectsBrokenUnusedStream() throws {
        let original = try fixture(text: "body")
        let tree = try OLECompoundDocument(data: original).storageTree()
        var streams = [[String]: Data]()
        for path in tree.streamPaths { streams[path] = try tree.stream(at: path) }
        streams[["unused"]] = Data([1, 2, 3])
        var damaged = try MSGEmbeddedWriter.compound(streams)
        let directory = Int(damaged.legacyUInt32(at: 48) + 1) * 512
        for offset in stride(from: directory, to: directory + 1024, by: 128) {
            let length = Int(damaged.legacyUInt16(at: offset + 64))
            if length >= 2, String(data: damaged.subdata(in: offset..<offset + length - 2), encoding: .utf16LittleEndian) == "unused" {
                put32(0xFFFF_FFFE, at: offset + 116, in: &damaged)
                break
            }
        }
        XCTAssertThrowsError(try MSGMessage.read(damaged))
    }

    func testNativeBodyWinsOverStaleAlternative() throws {
        let bytes = try fixture(text: "CURRENT_TEXT")
        let tree = try OLECompoundDocument(data: bytes).storageTree()
        var streams = [[String]: Data]()
        for path in tree.streamPaths { streams[path] = try tree.stream(at: path) }
        let html = Data("<p>STALE_HTML</p>".utf8)
        let compressed = try XCTUnwrap(Data(base64Encoded: "JgAAACsAAABMWkZ10YSbWQMACgByY3BnMTI1YDIgSGVsCQAOaiECfQ+g"))
        streams[["__substg1.0_10130102"]] = html
        streams[["__substg1.0_10090102"]] = compressed
        for native: UInt32 in [1, 2, 3, 4] {
            streams[["__properties_version1.0"]] = propertyTable([
                (0x001A001F, 18), (0x1000001F, 26), (0x10130102, UInt32(html.count)),
                (0x10090102, UInt32(compressed.count)), (0x10160003, native)
            ], header: 32)
            if native == 4 {
                XCTAssertThrowsError(try MSGMessage.read(MSGEmbeddedWriter.compound(streams)))
                continue
            }
            let message = try MSGMessage.read(MSGEmbeddedWriter.compound(streams))
            switch (native, message.body) {
            case (1, .text(let text)): XCTAssertEqual(text, "CURRENT_TEXT")
            case (2, .rtf(let data)): XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Hello Hello Hello!"))
            case (3, .html(let text)): XCTAssertEqual(text, "<p>STALE_HTML</p>")
            default: XCTFail("Wrong native body selected")
            }
        }
    }

    func testExternalMessagesDecodeBodiesAndByteExactAttachments() throws {
        guard let path = ProcessInfo.processInfo.environment["POORMANS_MSG_MESSAGE_REFERENCE"] else {
            throw XCTSkip("External MSG message reference not configured")
        }
        struct Attachment: Decodable { let base64: String }
        struct Ref: Decodable { let file: String; let subject: String; let attachments: [Attachment] }
        let url = URL(fileURLWithPath: path)
        let refs = try JSONDecoder().decode([Ref].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(refs.count, 1)
        for ref in refs {
            let source = url.deletingLastPathComponent().appendingPathComponent(ref.file)
            let original = try Data(contentsOf: source)
            let message = try MSGMessage.read(original)
            XCTAssertEqual(try message.headers.first { $0.name == "subject" }.map { try MIMEMessage.decodedHeader($0.value).trimmingCharacters(in: .whitespacesAndNewlines) }, ref.subject)
            switch message.body {
            case .text(let value), .html(let value): XCTAssertFalse(value.isEmpty)
            case .rtf(let bytes): XCTAssertTrue(bytes.starts(with: Data(#"{\rtf"#.utf8)))
            }
            let ordinary = message.attachments.filter { $0.mediaType != "application/vnd.ms-outlook" }
            XCTAssertEqual(ordinary.count, ref.attachments.count)
            for (attachment, expected) in zip(ordinary, ref.attachments) {
                XCTAssertEqual(attachment.data, Data(base64Encoded: expected.base64))
            }
            for attachment in message.attachments where attachment.mediaType == "application/vnd.ms-outlook" {
                _ = try MSGMessage.read(attachment.data)
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    private func fixture(text: String, attachment: Data? = nil, method: UInt32 = 1,
                         omitBodyStream: Bool = false, wrongCount: Bool = false) throws -> Data {
        let messageClass = try XCTUnwrap("IPM.Note".data(using: .utf16LittleEndian))
        let body = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        var root = propertyTable([(0x001A001F, UInt32(messageClass.count + 2)), (0x1000001F, UInt32(body.count + 2))], header: 32)
        var streams: [[String]: Data] = [["__properties_version1.0"]: root, ["__substg1.0_001A001F"]: messageClass]
        if !omitBodyStream { streams[["__substg1.0_1000001F"]] = body }
        if let attachment {
            put32(wrongCount ? 2 : 1, at: 20, in: &root)
            streams[["__properties_version1.0"]] = root
            let name = try XCTUnwrap("../../escape.bin".data(using: .utf16LittleEndian))
            let storage = "__attach_version1.0_#00000000"
            streams[[storage, "__properties_version1.0"]] = propertyTable([
                (0x37050003, method), (0x37010102, UInt32(attachment.count)), (0x3707001F, UInt32(name.count + 2))
            ], header: 8)
            streams[[storage, "__substg1.0_37010102"]] = attachment
            streams[[storage, "__substg1.0_3707001F"]] = name
        }
        return try MSGEmbeddedWriter.compound(streams)
    }

    private func propertyTable(_ entries: [(UInt32, UInt32)], header: Int) -> Data {
        var bytes = Data(repeating: 0, count: header + entries.count * 16)
        for (index, entry) in entries.enumerated() {
            put32(entry.0, at: header + index * 16, in: &bytes)
            put32(6, at: header + index * 16 + 4, in: &bytes)
            put32(entry.1, at: header + index * 16 + 8, in: &bytes)
        }
        return bytes
    }
    private func put32(_ value: UInt32, at offset: Int, in data: inout Data) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
}
