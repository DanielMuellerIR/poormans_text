import Foundation
import XCTest
@testable import PoorMansTextCore

final class MSGAdapterTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PoorMansMSGAdapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testHTMLInlineImageSafeAttachmentsAndEmbeddedMail() throws {
        let bytes = try synthetic()
        let source = root.appendingPathComponent("message.data")
        try bytes.write(to: source, options: .withoutOverwriting)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertEqual(result.format, .msg)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("| Header | Value |\n"))
        XCTAssertTrue(markdown.contains("MSG_BODY_MARKER Grüße 日本 😀"))
        XCTAssertTrue(markdown.contains("![inline]"))
        XCTAssertFalse(markdown.contains("cid:picture"))
        XCTAssertFalse(markdown.contains("../outside.png"))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "html.remoteImagesKeptAsLinks" })
        XCTAssertTrue(result.diagnostics.contains { $0.code == "html.missingImagesDropped" })
        let attachments = result.assets.filter { $0.deletingLastPathComponent().lastPathComponent == "attachments" }
        XCTAssertEqual(attachments.count, 3)
        let exported = try XCTUnwrap(attachments.first { $0.pathExtension == "msg" })
        _ = try MSGMessage.read(Data(contentsOf: exported))
        XCTAssertTrue(try attachments.contains { try Data(contentsOf: $0) == Data([0, 255, 1, 2]) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.bin").path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        if let path = ProcessInfo.processInfo.environment["POORMANS_MSG_SYNTHETIC"] {
            try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
    }

    func testNativeRTFPictureUsesOnlyStagedResources() throws {
        let imageURL = try XCTUnwrap(Bundle.module.url(forResource: "fixture", withExtension: "png", subdirectory: "Fixtures/WordProcessing"))
        let image = try Data(contentsOf: imageURL)
        let hex = image.map { String(format: "%02x", $0) }.joined()
        let rtf = Data((#"{\rtf1\ansi\ansicpg1252 RTFBODY Gr\u252?\u223?e {\pict\pngblip "# + hex + "}}").utf8)
        var compressed = Data(repeating: 0, count: 16)
        put32(UInt32(rtf.count + 12), at: 0, in: &compressed)
        put32(UInt32(rtf.count), at: 4, in: &compressed)
        put32(0x414C454D, at: 8, in: &compressed)
        compressed += rtf
        let messageClass = try XCTUnwrap("IPM.Note".data(using: .utf16LittleEndian))
        let bytes = try MSGEmbeddedWriter.compound([
            ["__properties_version1.0"]: table([(0x001A001F, UInt32(messageClass.count + 2)),
                (0x10090102, UInt32(compressed.count)), (0x10160003, 2)], header: 32),
            ["__substg1.0_001A001F"]: messageClass, ["__substg1.0_10090102"]: compressed
        ])
        let source = root.appendingPathComponent("rtf-picture.msg")
        try bytes.write(to: source, options: .withoutOverwriting)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("RTFBODY Grüße"))
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), image)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        if let path = ProcessInfo.processInfo.environment["POORMANS_MSG_RTF_SYNTHETIC"] {
            try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
    }

    func testTextbundleAndDestinationCollisionProtectSource() throws {
        let bytes = try synthetic()
        let source = root.appendingPathComponent("message.msg")
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
            options: ConversionOptions(frontmatter: true, outputLayout: .textbundle)))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertTrue(result.assets.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "assets" })
        XCTAssertTrue(markdown.contains("](assets/"))
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source,
            options: ConversionOptions(frontmatter: true, outputLayout: .textbundle))))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testDefectiveMSGLeavesNoOutput() throws {
        let source = root.appendingPathComponent("broken.msg")
        let bytes = Data("not an OLE container".utf8)
        try bytes.write(to: source)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source)))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["broken.msg"])
    }

    func testExternalMSGsUseTheSharedEngine() throws {
        guard let path = ProcessInfo.processInfo.environment["POORMANS_MSG_CORPUS"] else { throw XCTSkip("External MSG corpus not configured") }
        struct File: Decodable { let path: String }
        struct Manifest: Decodable { let files: [File] }
        let corpus = URL(fileURLWithPath: path)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: corpus.appendingPathComponent("manifest.json")))
        var count = 0
        var outputs = [[String: String]]()
        for file in manifest.files where file.path.hasSuffix(".msg") {
            let name = URL(fileURLWithPath: file.path).lastPathComponent
            let source = root.appendingPathComponent(name)
            let bytes = try Data(contentsOf: corpus.appendingPathComponent(name))
            try bytes.write(to: source, options: .withoutOverwriting)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
            XCTAssertEqual(result.format, .msg)
            XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).hasPrefix("| Header | Value |\n"))
            let message = try MSGMessage.read(bytes)
            let saved = result.assets.filter { $0.deletingLastPathComponent().lastPathComponent == "attachments" }
            XCTAssertEqual(saved.count, message.attachments.count)
            for attachment in message.attachments {
                XCTAssertTrue(try saved.contains { try Data(contentsOf: $0) == attachment.data })
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            if let export = ProcessInfo.processInfo.environment["POORMANS_MSG_OUTPUT_CHECK"] {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: export), withIntermediateDirectories: true)
                let destination = URL(fileURLWithPath: export).appendingPathComponent(name)
                try FileManager.default.copyItem(at: result.outputDirectory, to: destination)
                outputs.append(["file": name, "markdown": destination.appendingPathComponent(result.markdownFile.lastPathComponent).path])
            }
            count += 1
        }
        XCTAssertEqual(count, 6)
        if let export = ProcessInfo.processInfo.environment["POORMANS_MSG_OUTPUT_CHECK"] {
            try JSONSerialization.data(withJSONObject: outputs).write(to: URL(fileURLWithPath: export).appendingPathComponent("outputs.json"))
        }
    }

    private func synthetic() throws -> Data {
        let image = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "fixture", withExtension: "png", subdirectory: "Fixtures/WordProcessing")))
        var streams = [[String]: Data]()
        var properties = [(UInt32, UInt32)]()
        func text(_ id: UInt16, _ value: String, storage: [String], entries: inout [(UInt32, UInt32)]) throws {
            let data = try XCTUnwrap(value.data(using: .utf16LittleEndian))
            let tag = UInt32(id) << 16 | 0x001F
            entries.append((tag, UInt32(data.count + 2)))
            streams[storage + [String(format: "__substg1.0_%08X", tag)]] = data
        }
        try text(0x001A, "IPM.Note", storage: [], entries: &properties)
        try text(0x0037, "MSG synthetic Grüße", storage: [], entries: &properties)
        try text(0x0C1F, "sender@example.test", storage: [], entries: &properties)
        let html = Data("<p>MSG_BODY_MARKER Grüße 日本 😀</p><img alt='inline' src='cid:picture'><img alt='remote' src='https://example.invalid/p.png'><img alt='missing' src='../outside.png'>".utf8)
        properties += [(0x10130102, UInt32(html.count)), (0x3FDE0003, 65001)]
        streams[["__substg1.0_10130102"]] = html
        for index in 0..<3 {
            let storage = [String(format: "__attach_version1.0_#%08X", index)]
            var entries: [(UInt32, UInt32)] = [(0x37050003, index == 2 ? 5 : 1)]
            try text(0x3707, index == 0 ? "inline.png" : index == 1 ? "../../escape.bin" : "Nested.msg", storage: storage, entries: &entries)
            if index == 0 {
                try text(0x3712, "picture", storage: storage, entries: &entries)
                try text(0x370E, "image/png", storage: storage, entries: &entries)
            }
            if index < 2 {
                let data = index == 0 ? image : Data([0, 255, 1, 2])
                entries.append((0x37010102, UInt32(data.count)))
                streams[storage + ["__substg1.0_37010102"]] = data
            } else {
                entries.append((0x3701000D, 0))
                let embedded = storage + ["__substg1.0_3701000D"]
                var child = [(UInt32, UInt32)]()
                try text(0x001A, "IPM.Note", storage: embedded, entries: &child)
                try text(0x0037, "Nested synthetic", storage: embedded, entries: &child)
                try text(0x1000, "Nested body Grüße", storage: embedded, entries: &child)
                streams[embedded + ["__properties_version1.0"]] = table(child, header: 24)
            }
            streams[storage + ["__properties_version1.0"]] = table(entries, header: 8)
        }
        var root = table(properties, header: 32)
        put32(3, at: 20, in: &root)
        streams[["__properties_version1.0"]] = root
        return try MSGEmbeddedWriter.compound(streams)
    }

    private func table(_ entries: [(UInt32, UInt32)], header: Int) -> Data {
        var data = Data(repeating: 0, count: header + entries.count * 16)
        for (index, entry) in entries.enumerated() {
            put32(entry.0, at: header + index * 16, in: &data)
            put32(6, at: header + index * 16 + 4, in: &data)
            put32(entry.1, at: header + index * 16 + 8, in: &data)
        }
        return data
    }
    private func put32(_ value: UInt32, at offset: Int, in data: inout Data) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
}
