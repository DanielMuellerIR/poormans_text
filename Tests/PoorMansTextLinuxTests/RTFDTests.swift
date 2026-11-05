#if os(Linux)
import Foundation
import Glibc
import XCTest
@testable import PoorMansTextCore

final class RTFDTests: XCTestCase {
    private func package(_ body: Data, asset: Data? = nil, filename: String = "image.png") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RTFD-\(UUID().uuidString).rtfd")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try body.write(to: url.appendingPathComponent("TXT.rtf"))
        if let asset { try asset.write(to: url.appendingPathComponent(filename)) }
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


    func testSingleFrameRasterAttachmentsKeepOriginalBytesExtensionAndPosition() throws {
        let fixtures: [String: String] = [
            "bmp": "Qk12AgAAAAAAADYAAAAoAAAAEAAAAAwAAAABABgAAAAAAEACAADEDgAAxA4AAAAAAAAAAAAAAAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/",
            "jpg": "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAMABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi6KKK+ZP3E//Z",
            "tiff": "SUkqAAgAAAAKAAABBAABAAAAEAAAAAEBBAABAAAADAAAAAIBAwADAAAAhgAAAAMBAwABAAAAAQAAAAYBAwABAAAAAgAAABEBBAABAAAAjAAAABUBAwABAAAAAwAAABYBBAABAAAADAAAABcBBAABAAAAQAIAABwBAwABAAAAAQAAAAAAAAAIAAgACAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAA=",
            "gif": "R0lGODdhEAAMAIEAAP8AAAAAAAAAAAAAACwAAAAAEAAMAAAIGQABCBxIsKDBgwgTKlzIsKHDhxAjSpwoMCAAOw==",
            "webp": "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoQAAwAAUAmJaACdLoB+AADsAD+8ut//NgVzXPv9//S4P0uD9Lg/9KQAAA="
        ]
        for (extensionName, encoded) in fixtures {
            let image = try XCTUnwrap(Data(base64Encoded: encoded))
            let filename = "local picture." + extensionName
            let before = #"{\rtf1 BEFORE "#
            let after = #" AFTER}"#
            let rtf = Data((before + "{\\NeXTGraphic " + filename + " \\width16 \\height12}" + after).utf8)
            let url = try package(rtf, asset: image, filename: filename)
            let prepared = try LinuxRTFDPreparation.prepare(package: url)
            let html = try prepared.restoringImages(in: String(decoding: prepared.data, as: UTF8.self), packageName: "source.rtfd", inputURL: url)
            XCTAssertEqual(html, before + "<img src=\"source.rtfd/local%20picture." + extensionName + "\" alt=\"image\">" + after)
            XCTAssertEqual(prepared.viewerLimitedFormats, extensionName == "tiff" ? ["tiff"] : [])
            XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(filename)), image)
            XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("TXT.rtf")), rtf)
        }
    }

    func testRejectsMultipleFramesAndMismatchedRasterExtensions() throws {
        let multipleFrames: [String: String] = [
            "gif": "R0lGODlhEAAMAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAEAAMAAAIGQABCBxIsKDBgwgTKlzIsKHDhxAjSpwoMCAAIfkEAQoAAQAsAAAAABAADACBAAD/AAAAAAAAAAAACBkAAQgcSLCgwYMIEypcyLChw4cQI0qcKDAgADs=",
            "tiff": "SUkqAAgAAAAKAAABBAABAAAAEAAAAAEBBAABAAAADAAAAAIBAwADAAAAhgAAAAMBAwABAAAAAQAAAAYBAwABAAAAAgAAABEBBAABAAAAjAAAABUBAwABAAAAAwAAABYBBAABAAAADAAAABcBBAABAAAAQAIAABwBAwABAAAAAQAAANgCAAAIAAgACAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAD/AAAAAAAASUkqAAgAAAAKAAABBAABAAAAEAAAAAEBBAABAAAADAAAAAIBAwADAAAAVgMAAAMBAwABAAAAAQAAAAYBAwABAAAAAgAAABEBBAABAAAAXAMAABUBAwABAAAAAwAAABYBBAABAAAADAAAABcBBAABAAAAQAIAABwBAwABAAAAAQAAAAAAAAAIAAgACAAAAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAP8AAAAA",
            "png": "iVBORw0KGgoAAAANSUhEUgAAABAAAAAMCAIAAADkharWAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAAQAAAADAAAAAAAAAAAAAEACgAAYtH5jgAAABhJREFUeJxj/M9AGmAiUT3DqAZiwHAIJQBmrwEXbkCYywAAABpmY1RMAAAAAQAAABAAAAAMAAAAAAAAAAAAAQAKAAD5ohNaAAAAHmZkQVQAAAACeJxjZGD4z0AKYCJJNcOoBuLAcAhWAGSxARfV56W+AAAAAElFTkSuQmCC",
            "webp": "UklGRsQAAABXRUJQVlA4WAoAAAACAAAADwAACwAAQU5JTQYAAAAAAAAAAABBTk1GSgAAAAAAAAAAAA8AAAsAAGQAAAJWUDggMgAAADABAJ0BKhAADAABQCYloAADcAD+8ut///mwP/bz/wR6Af//0uD//pcH//S4P/SkAAAAQU5NRkYAAAAAAAAAAAAPAAALAABkAAAAVlA4IC4AAAA0AQCdASoQAAwAAAAmJaAAA3AA/vtV4///S4P/+lwf/9Lg/9Lg//rV5Vesq6AA"
        ]
        for (extensionName, encoded) in multipleFrames {
            let image = try XCTUnwrap(Data(base64Encoded: encoded))
            let filename = "image." + extensionName
            let url = try package(Data(("{\\rtf1 BEFORE {\\NeXTGraphic " + filename + "} AFTER}").utf8), asset: image, filename: filename)
            XCTAssertThrowsError(try LinuxRTFDPreparation.prepare(package: url), extensionName) { error in
                guard case ConversionError.invalidRichText = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAMCAIAAADkharWAAAAGElEQVR4nGP8z0AaYCJRPcOoBmLAcAglAGavARduQJjLAAAAAElFTkSuQmCC")!
        let mismatch = try package(Data(#"{\rtf1{\NeXTGraphic image.jpg}}"#.utf8), asset: png, filename: "image.jpg")
        XCTAssertThrowsError(try LinuxRTFDPreparation.prepare(package: mismatch))
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
