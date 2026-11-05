#if os(Linux)
import Foundation
import Glibc
import XCTest
@testable import PoorMansTextCore

final class RTFDTests: XCTestCase {
    private func package(_ body: Data, asset: Data? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RTFD-\(UUID().uuidString).rtfd")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try body.write(to: url.appendingPathComponent("TXT.rtf"))
        if let asset { try asset.write(to: url.appendingPathComponent("image.png")) }
        return url
    }

    func testPreservesRTFBytesAroundValidatedPNGAndRestoresOnePosition() throws {
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAMCAIAAADkharWAAAAGElEQVR4nGP8z0AaYCJRPcOoBmLAcAglAGavARduQJjLAAAAAElFTkSuQmCC")!
        let before = #"{\rtf1\ansi Gr\'fc\'dfe "#
        let attachment = #"{\NeXTGraphic image.png \width16 \height12}"#
        let after = #" after\par}"#
        let original = Data((before + attachment + after).utf8)
        let url = try package(original, asset: image)
        let prepared = try LinuxRTFDPreparation.prepare(package: url)
        let text = String(decoding: prepared.data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(before))
        XCTAssertTrue(text.hasSuffix(after))
        XCTAssertEqual(prepared.representedNames, ["image.png"])
        let html = try prepared.restoringImages(in: text, packageName: "source.rtfd", inputURL: url)
        XCTAssertTrue(html.contains(#"<img src="source.rtfd/image.png" alt="image">"#))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("TXT.rtf")), original)
        XCTAssertThrowsError(try prepared.restoringImages(in: "missing", packageName: "source.rtfd", inputURL: url))
    }

    func testLeavesNonAttachmentBytesAndBinaryCodeExamplesUnchanged() throws {
        let prefix = Data(#"{\rtf1\ansi\ansicpg1252 Gr\'fc\'dfe {\*\unknown {\NeXTGraphic https://example.invalid/x.png } {\object\bin5 {\}}x}} Text}"#.utf8)
        let url = try package(prefix)
        let prepared = try LinuxRTFDPreparation.prepare(package: url)
        XCTAssertEqual(prepared.data, prefix)
        XCTAssertTrue(prepared.representedNames.isEmpty)
    }

    func testRejectsUnsafeOrMissingAttachmentReferences() throws {
        for name in ["../image.png", "/image.png", "https://example.invalid/image.png", "missing.png"] {
            let url = try package(Data("{\\rtf1{\\NeXTGraphic \(name) \\width1 \\height1}}".utf8))
            XCTAssertThrowsError(try LinuxRTFDPreparation.prepare(package: url), name)
        }
    }

    func testRejectsMemberSymlinkAndFIFOWithoutBlocking() throws {
        let data = Data(#"{\rtf1{\NeXTGraphic image.png \width1 \height1}}"#.utf8)
        let linked = try package(data)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("image.png"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertThrowsError(try LinuxRTFDPreparation.prepare(package: linked))
        let piped = try package(data)
        XCTAssertEqual(mkfifo(piped.appendingPathComponent("image.png").path, 0o600), 0)
        XCTAssertThrowsError(try LinuxRTFDPreparation.prepare(package: piped))
    }

    func testRejectsDecoderBypassAndMalformedGroups() throws {
        for rtf in [#"{\rtf1{\object\objdata00}}"#, #"{\rtf1{\pict\jpegblip FFD8}}"#, #"{\rtf1{\NeXTGraphic image.png}"#, #"{\rtf1{\NeXTGraphic image.png \bin100 x}}"#] {
            XCTAssertThrowsError(try LinuxRTFDPreparation.prepare(package: package(Data(rtf.utf8))))
        }
    }

    func testRejectsReaderImagesOutsideValidatedPackageReferences() throws {
        let url = try package(Data(#"{\rtf1 Text}"#.utf8))
        let prepared = try LinuxRTFDPreparation.prepare(package: url)
        XCTAssertThrowsError(try prepared.restoringImages(in: #"<p><img src="unknown.jpg"></p>"#, packageName: "source.rtfd", inputURL: url))
    }

    func testLiteralListsKeepInlineMarkupAndManualBreaks() throws {
        let html = "<p>Title</p><p>• First<br>Continuation</p>\n<p><strong>- Second</strong></p><p>Normal • stays</p><p>•no space</p>"
        let normalized = try LinuxRTFDPreparation.normalizingLiteralLists(in: html)
        XCTAssertEqual(normalized, "<p>Title</p><ul><li>First<br>Continuation</li>\n<li><strong>Second</strong></li></ul><p>Normal • stays</p><p>•no space</p>")
    }
}
#endif
