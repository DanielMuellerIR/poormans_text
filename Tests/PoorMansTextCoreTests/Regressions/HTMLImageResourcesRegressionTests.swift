import Foundation
import XCTest
#if os(macOS)
import AppKit
import ImageIO
#endif
@testable import PoorMansTextCore

final class HTMLImageResourcesRegressionTests: XCTestCase {
    func testActiveAndUnknownSchemesNeverBecomeLinksEvenWithAWebBase() throws {
        let html = """
        <img src="javascript:alert(1)" alt="Skript">
        <img src="vbscript:x" alt="Alt">
        <img src="mailto:a@b.c" alt="Mail">
        <img src="https://example.com/x.png" alt="Bild">
        """
        let resolution = try resolve(html, baseURL: URL(string: "https://example.com/seite.html"))

        XCTAssertEqual(resolution.remoteImagesKeptAsLinks, 1)
        XCTAssertEqual(resolution.missingImagesDropped, 3)
        XCTAssertFalse(resolution.html.contains("javascript:"), resolution.html)
        XCTAssertFalse(resolution.html.contains("vbscript:"), resolution.html)
        XCTAssertTrue(resolution.html.contains("<a href=\"https://example.com/x.png\">Bild</a>"), resolution.html)
    }

    func testAFIFONextToTheSourceIsNotAnImageAndDoesNotBlock() throws {
        let root = try makeRegressionDirectory()
        let fifo = root.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let resolution = try resolve("<img src=\"pipe.png\" alt=\"Pipe\">", baseDirectory: root)

        XCTAssertEqual(resolution.missingImagesDropped, 1)
        XCTAssertEqual(resolution.html, "Pipe")
    }

    func testALocalImageIsCopiedThroughTheVerifiedStagingPath() throws {
        let root = try makeRegressionDirectory()
        let imageBytes = try RegressionFixtures.png()
        try imageBytes.write(to: root.appendingPathComponent("bild.png"))

        let resolution = try resolve("<img src=\"bild.png\" alt=\"Bild\">", baseDirectory: root)

        XCTAssertEqual(resolution.html, "<img src=\"external/local01.png\" alt=\"Bild\">")
        XCTAssertEqual(resolution.missingImagesDropped, 0)
    }

    func testUnquotedAttributesAreReadLikeQuotedOnes() throws {
        let root = try makeRegressionDirectory()
        let imageBytes = try RegressionFixtures.png()
        try imageBytes.write(to: root.appendingPathComponent("bild.png"))

        let resolution = try resolve("<img src=bild.png alt=Bild>", baseDirectory: root)

        XCTAssertEqual(resolution.html, "<img src=\"external/local01.png\" alt=Bild>")
        XCTAssertEqual(resolution.missingImagesDropped, 0)

        let remote = try resolve("<img src=https://example.com/x.png alt=Fern>")
        XCTAssertEqual(remote.html, "<a href=\"https://example.com/x.png\">Fern</a>")
    }

    func testALocallySavedWebArchiveFindsItsFileSubresources() throws {
        let imageBytes = try RegressionFixtures.png()
        let subresources = [
            "file:///Users/x/Seite_files/a.png": HTMLImageSourceResolver.Subresource(data: imageBytes, mimeType: "image/png"),
            "file:///Users/x/b.png": HTMLImageSourceResolver.Subresource(data: imageBytes, mimeType: "image/png"),
        ]
        let html = """
        <img src="Seite_files/a.png" alt="Relativ">
        <img src="file:///Users/x/b.png" alt="Absolut">
        <img src="file:///Users/x/fehlt.png" alt="Fehlt">
        """
        let resolution = try resolve(html, baseURL: URL(string: "file:///Users/x/Seite.html"), subresources: subresources)

        XCTAssertTrue(resolution.html.contains("<img src=\"external/resource01.png\" alt=\"Relativ\">"), resolution.html)
        XCTAssertTrue(resolution.html.contains("<img src=\"external/resource02.png\" alt=\"Absolut\">"), resolution.html)
        XCTAssertTrue(resolution.html.contains("Fehlt"), resolution.html)
        XCTAssertFalse(resolution.html.contains("file:///Users/x/fehlt.png"), resolution.html)
        XCTAssertEqual(resolution.missingImagesDropped, 1)
        XCTAssertEqual(resolution.remoteImagesKeptAsLinks, 0)
    }

    func testHTMLImageCharacterReferencesResolveWithoutChangingSources() throws {
        let root = try makeRegressionDirectory()
        #if os(macOS)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        #else
        let png = try RegressionFixtures.png()
        #endif
        let image = root.appendingPathComponent("bild&.png")
        try png.write(to: image)
        let html = #"<html><body><img src="bild&amp;&#46;png" alt="LOCAL"><img src="https:&#x2f;&#47;example.com&#47;remote.png" alt="REMOTE"></body></html>"#
        let source = root.appendingPathComponent("entities.html")
        let bytes = Data(html.utf8)
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertEqual(result.assets.count, 1)
        if let asset = result.assets.first { XCTAssertEqual(try Data(contentsOf: asset), png) }
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[REMOTE](https://example.com/remote.png)"), markdown)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: image), png)
        let work = root.appendingPathComponent("archive-work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        let resolution = try HTMLImageSourceResolver.resolve(html: #"<img src="https:&#47;&#47;example.com&#47;image.png">"#,
            baseDirectory: nil, baseURL: nil, subresources: ["https://example.com/image.png": .init(data: png, mimeType: "image/png")], workDirectory: work)
        XCTAssertEqual(resolution.missingImagesDropped, 0)
        XCTAssertEqual(resolution.remoteImagesKeptAsLinks, 0)
        XCTAssertTrue(resolution.html.contains("external/resource01.png"), resolution.html)
    }

    func testHTMLImageBudgetCountsEveryPhysicalCopyAndKeepsRepeatedReferencesCheap() throws {
        let root = try makeRegressionDirectory()
        let png = try RegressionFixtures.png()
        try png.write(to: root.appendingPathComponent("first.png"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("first.png"), to: root.appendingPathComponent("second.png"))
        let archived = ["https://invalid.test/p.png": HTMLImageSourceResolver.Subresource(data: png, mimeType: "image/png")]
        func resolve(_ html: String, bytes: Int, count: Int) throws -> HTMLImageSourceResolver.Resolution {
            let work = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            return try HTMLImageSourceResolver.resolve(html: html, baseDirectory: root, baseURL: nil,
                subresources: archived, workDirectory: work, maximumImageBytes: bytes, maximumImageCount: count)
        }
        let first = #"<img src="first.png">"#
        XCTAssertNoThrow(try resolve(first + first, bytes: png.count, count: 1))
        for html in [first + #"<img src="second.png">"#,
                     first + #"<img src="https://invalid.test/p.png">"#,
                     first + "<img src=\"data:image/png;base64,\(png.base64EncodedString())\">"] {
            XCTAssertThrowsError(try resolve(html, bytes: png.count, count: 2))
            XCTAssertThrowsError(try resolve(html, bytes: png.count * 2, count: 1))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("first.png")), png)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("second.png")), png)
    }

    func testHTMLAttributeLegacyReferencesRespectAttributeBoundaries() throws {
        for (input, expected) in [("a&amp.png", "a&.png"), ("a&amp;.png", "a&.png"),
                                  ("a&copy.png", "a©.png"), ("a&copy;.png", "a©.png"),
                                  ("&amp", "&"), ("&notin;", "∉"), ("&notin", "&notin"),
                                  ("&copyx", "&copyx"), ("&copy7", "&copy7"),
                                  ("&copy=", "&copy="), ("&apos.png", "&apos.png"),
                                  ("&copy;x", "©x"), ("&bogus;", "&bogus;")] {
            XCTAssertEqual(try HTMLImageAttributes.decodedValue(input), expected, input)
        }
        let root = try makeRegressionDirectory()
        let png = try RegressionFixtures.png()
        for name in ["a&.png", "a©.png"] {
            try png.write(to: root.appendingPathComponent(name))
        }
        let original = Data(#"<html><body><p>START</p><img src="a&amp.png"><img src="a&amp;.png"><img src="a&copy.png"><img src="a&copy;.png"><p>END</p></body></html>"#.utf8)
        let source = root.appendingPathComponent("images.html")
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertEqual(result.assets.count, 2)
        for asset in result.assets { XCTAssertEqual(try Data(contentsOf: asset), png) }
        XCTAssertFalse(result.diagnostics.contains { $0.code == ConversionWarning.missingImagesDropped(1).code })
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "![").count - 1, 4, markdown)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testHTMLNumericReferencesUseHistoricalC1Mappings() throws {
        let expected = ["€", "\u{81}", "‚", "ƒ", "„", "…", "†", "‡", "ˆ", "‰", "Š", "‹", "Œ", "\u{8D}", "Ž", "\u{8F}",
                        "\u{90}", "‘", "’", "“", "”", "•", "–", "—", "˜", "™", "š", "›", "œ", "\u{9D}", "ž", "Ÿ"]
        for (offset, character) in expected.enumerated() {
            let number = 0x80 + offset
            for reference in ["&#\(number);", "&#x\(String(number, radix: 16));", "&#X\(String(number, radix: 16).uppercased())"] {
                XCTAssertEqual(try HTMLImageAttributes.decodedValue("a\(reference).png"), "a\(character).png", reference)
            }
        }
        for (input, output) in [("&#0;", "�"), ("&#xD800;", "�"), ("&#1114112;", "�"),
                                ("&#999999999999999999999;", "�"), ("&#127;", "\u{7F}"),
                                ("&#160;", "\u{A0}"), ("&#x1F600;", "😀"), ("&#xFFFF;", "\u{FFFF}")] {
            XCTAssertEqual(try HTMLImageAttributes.decodedValue(input), output, input)
        }
    }

    func testHTMLNumericImageReferencesPreserveAssetsAndSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTHTMLImageResources-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try RegressionFixtures.png()
        let images = [(128, "€"), (146, "’"), (150, "–"), (159, "Ÿ")]
        var tags = [String]()
        for (number, character) in images {
            try png.write(to: root.appendingPathComponent("a\(character).png"))
            tags.append("<img src=\"a&#\(number);.png\" alt=\"DEC\(number)\">")
            tags.append("<img src=\"a&#x\(String(number, radix: 16));.png\" alt=\"HEX\(number)\">")
        }
        let original = Data(("<html><body><p>STARTTOKEN</p>" + tags.joined() + "<p>ENDTOKEN</p></body></html>").utf8)
        let source = root.appendingPathComponent("images.html")
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertEqual(result.assets.count, images.count)
        for asset in result.assets { XCTAssertEqual(try Data(contentsOf: asset), png) }
        XCTAssertFalse(result.diagnostics.contains { $0.code == "html.missingImagesDropped" })
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "![").count - 1, images.count * 2, markdown)
        for token in ["STARTTOKEN", "ENDTOKEN"] {
            XCTAssertEqual(markdown.components(separatedBy: token).count - 1, 1, markdown)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        for (_, character) in images {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a\(character).png")), png)
        }
    }

    func testCorruptPNGPixelPayloadIsRejectedThroughAllResourcePaths() throws {
        let root = try makeRegressionDirectory()
        // Gültige Chunk-Prüfsummen kaschieren hier absichtlich einen defekten Pixelstrom.
        let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAADklEQVRub3QtdmFsaWQtemxpYlp0dn0AAAAASUVORK5CYII="))
        try bytes.write(to: root.appendingPathComponent("broken.png"))
        for index in 0..<3 {
            let work = root.appendingPathComponent("broken-work\(index)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let target = index == 0 ? "data:image/png;base64,\(bytes.base64EncodedString())" : index == 1 ? "broken.png" : "https://example.invalid/broken.png"
            let resources: [String: HTMLImageSourceResolver.Subresource] = index == 2 ? [target: .init(data: bytes, mimeType: "image/png")] : [:]
            let result = try HTMLImageSourceResolver.resolve(html: "<img alt=\"ALTTOKEN\" src=\"\(target)\">", baseDirectory: root, baseURL: nil, subresources: resources, workDirectory: work)
            XCTAssertEqual(result.html, "ALTTOKEN")
            XCTAssertEqual(result.missingImagesDropped, 1)
            XCTAssertTrue((try FileManager.default.subpathsOfDirectory(atPath: work.path)).allSatisfy { !$0.hasSuffix(".png") })
        }
    }

    func testTruncatedRasterImagesKeepAltTextAndReportLoss() throws {
        let root = try makeRegressionDirectory()
        for (index, bytes) in [Data(try RegressionFixtures.png().prefix(16)), try RegressionFixtures.png()].enumerated() {
            let source = root.appendingPathComponent("image\(index).html")
            let html = Data("<p>BEFORETOKEN</p><img alt=\"ALTTOKEN\" src=\"data:image/png;base64,\(bytes.base64EncodedString())\"><p>AFTERTOKEN</p>".utf8)
            try html.write(to: source)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
                destination: .directory(root.appendingPathComponent("image-output\(index)"))))
            let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for token in ["BEFORETOKEN", "ALTTOKEN", "AFTERTOKEN"] {
                XCTAssertEqual(output.components(separatedBy: token).count - 1, 1)
            }
            if index == 0 {
                XCTAssertTrue(result.assets.isEmpty)
                XCTAssertTrue(result.diagnostics.contains { $0.code == "html.missingImagesDropped" }, "\(result.diagnostics)")
            } else {
                let asset = try XCTUnwrap(result.assets.first)
                XCTAssertEqual(try Data(contentsOf: asset), bytes)
                #if os(macOS)
                let image = try XCTUnwrap(CGImageSourceCreateWithURL(asset as CFURL, nil))
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(image, 0, nil))
                #endif
            }
            XCTAssertEqual(try Data(contentsOf: source), html)
        }
    }

    func testTruncatedLocalAndArchivedRasterSourcesAreNotPublished() throws {
        let root = try makeRegressionDirectory()
        let bytes = Data(try RegressionFixtures.png().prefix(16))
        let local = root.appendingPathComponent("local.png")
        try bytes.write(to: local)
        for archived in [false, true] {
            let work = root.appendingPathComponent(archived ? "archive-work" : "local-work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let target = archived ? "https://example.invalid/picture.png" : "local.png"
            let resources: [String: HTMLImageSourceResolver.Subresource] = archived
                ? [target: .init(data: bytes, mimeType: "image/png")] : [:]
            let result = try HTMLImageSourceResolver.resolve(html: "<img alt=\"ALTTOKEN\" src=\"\(target)\">",
                baseDirectory: root, baseURL: nil, subresources: resources, workDirectory: work)
            XCTAssertEqual(result.html, "ALTTOKEN")
            XCTAssertEqual(result.missingImagesDropped, 1)
            let files = FileManager.default.enumerator(at: work, includingPropertiesForKeys: [.isRegularFileKey])!
            XCTAssertTrue(files.allObjects.compactMap { $0 as? URL }.allSatisfy {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true
            })
        }
        XCTAssertEqual(try Data(contentsOf: local), bytes)
    }

    private func resolve(
        _ html: String,
        baseDirectory: URL? = nil,
        baseURL: URL? = nil,
        subresources: [String: HTMLImageSourceResolver.Subresource] = [:]
    ) throws -> HTMLImageSourceResolver.Resolution {
        let work = try makeRegressionDirectory()
        return try HTMLImageSourceResolver.resolve(
            html: html,
            baseDirectory: baseDirectory,
            baseURL: baseURL,
            subresources: subresources,
            workDirectory: work
        )
    }
}
