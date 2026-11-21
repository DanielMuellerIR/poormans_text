import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import PoorMansTextCore

final class ENEXResourceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTENEXResources-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func digest(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func image(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }
    private func pdf() throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 40, height: 40)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
    private func resource(_ data: Data, mime: String, name: String, extra: String = "") -> String {
        "<resource><data encoding=\"base64\">" + data.base64EncodedString() + "</data><mime>" + ENMLConverter.escaped(mime)
        + "</mime><resource-attributes><file-name>" + ENMLConverter.escaped(name) + "</file-name></resource-attributes>" + extra + "</resource>"
    }
    private func note(_ content: String, resources: String = "", guid: String? = nil, title: String = "Same title") -> String {
        "<note" + (guid.map { " guid=\"" + $0 + "\"" } ?? "") + "><title>" + ENMLConverter.escaped(title)
        + "</title><content>" + ENMLConverter.escaped("<en-note>" + content + "</en-note>") + "</content>" + resources + "</note>"
    }
    private func source(_ notes: [String], name: String = "archive.enex") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(("<en-export>" + notes.joined() + "</en-export>").utf8).write(to: url)
        return url
    }
    private func media(_ data: Data, mime: String, label: String) -> String {
        "<en-media hash=\"" + digest(data) + "\" type=\"" + mime + "\" alt=\"" + label + "\"/>"
    }
    private func linkTargets(_ markdown: URL) throws -> [String] {
        let result = try ProcessRunner.run(executable: PandocTool.resolve(nil), arguments: ["-f", "gfm", "-t", "json", markdown.path], currentDirectory: markdown.deletingLastPathComponent(), captureStandardOutput: true)
        XCTAssertEqual(result.status, 0)
        let value = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        var targets: [String] = []
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                if object["t"] as? String == "Link", let content = object["c"] as? [Any], let target = content.last as? [String] { targets.append(target[0]) }
                else { for item in object.values { visit(item) } }
            } else if let array = value as? [Any] { for item in array { visit(item) } }
        }
        visit(value)
        return targets
    }

    func testPNGJPEGPDFAttachmentsDuplicatesAndEveryMediaReferenceKeepBytes() throws {
        let png = try image(.png), jpeg = try image(.jpeg), document = try pdf(), binary = Data([0, 255, 7])
        let resources = resource(png, mime: "image/png", name: "../../unsafe.command")
            + resource(png, mime: "image/png", name: "Same name.png")
            + resource(jpeg, mime: "image/jpeg", name: "Same name.png")
            + resource(document, mime: "application/pdf", name: "Document.pdf")
            + resource(binary, mime: "application/octet-stream", name: "[unsafe](javascript:bad).command")
        let content = "<p>RESOURCE_BODY_ONE</p>" + media(png, mime: "image/png", label: "PNG_ONE")
            + media(png, mime: "image/png", label: "PNG_TWO") + media(jpeg, mime: "image/jpeg", label: "JPEG_ONE")
            + media(document, mime: "application/pdf", label: "PDF_ONE") + media(binary, mime: "application/octet-stream", label: "BIN_ONE")
        let url = try source([note(content, resources: resources), note("<p>RESOURCE_BODY_TWO</p>", resources: resource(png, mime: "image/png", name: "Same name.png"))])
        let original = try Data(contentsOf: url)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let result = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary,
                options: .init(outputLayout: layout, conversionReport: true)))
            defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
            XCTAssertEqual(result.documents.count, 2)
            let first = result.documents[0]
            XCTAssertEqual(first.assets.count, 7)
            let originals = first.assets.filter { $0.path.contains("/attachments/") }
            XCTAssertEqual(originals.count, 5)
            XCTAssertEqual(originals.map(\.lastPathComponent), ["resource-000001.png", "resource-000002.png", "resource-000003.jpg", "resource-000004.pdf", "resource-000005.bin"])
            let bytes = try originals.map { try Data(contentsOf: $0) }
            XCTAssertEqual(bytes, [png, png, jpeg, document, binary])
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.documents[1].assets.first)), png)
            let text = try String(contentsOf: first.markdownFile, encoding: .utf8)
            for marker in ["RESOURCE_BODY_ONE", "PNG_ONE", "PNG_TWO", "JPEG_ONE", "PDF_ONE", "BIN_ONE"] {
                XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, marker)
            }
            XCTAssertEqual(text.components(separatedBy: "images/image01.png").count - 1, 2)
            XCTAssertTrue(text.contains("attachments/resource-000004.pdf"))
            XCTAssertFalse(first.assets.contains { $0.pathExtension == "command" })
            XCTAssertFalse(result.diagnostics.contains { $0.code.hasPrefix("enex.resourceMissing") || $0.code == "enex.resourcesNotImported" })
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
            XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testExplicitGUIDsResolveWhileMissingDuplicateAndConflictingIdentitiesStayLiteral() throws {
        let a = "11111111-1111-4111-8111-111111111111", b = "22222222-2222-4222-8222-222222222222", c = "33333333-3333-4333-8333-333333333333"
        func link(_ id: String, _ label: String) -> String { "<a href=\"evernote:///view/1/s1/" + id + "/" + id + "/\">" + label + "</a>" }
        let url = try source([
            note("<p>LINK_BODY_ONE</p>" + link(b, "RESOLVED_TARGET") + link(c, "MISSING_TARGET")
                + "<a href=\"evernote:///view/1/s1/" + a + "/" + b + "/\">CONFLICT_LINK</a>"
                + "<a href=\"https://www.evernote.com/l/shortened\">SHORT_LINK</a>", guid: a),
            note("<p>LINK_BODY_TWO</p><a href=\"https://www.evernote.com/shard/s1/nl/1/" + a + "/\">WEB_TARGET</a>", resources: "<guid>" + b + "</guid>")
        ], name: "link [unicode ü].enex")
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let result = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary, options: .init(outputLayout: layout)))
            defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
            let first = try String(contentsOf: result.documents[0].markdownFile, encoding: .utf8)
            for (origin, destination) in [(result.documents[0], result.documents[1]), (result.documents[1], result.documents[0])] {
                let targets = try linkTargets(origin.markdownFile)
                XCTAssertEqual(targets.count, 1)
                let target = try XCTUnwrap(targets.first)
                let resolved = try XCTUnwrap(URL(string: target, relativeTo: origin.markdownFile)).standardizedFileURL
                XCTAssertEqual(resolved.path.precomposedStringWithCanonicalMapping, destination.markdownFile.standardizedFileURL.path.precomposedStringWithCanonicalMapping)
                XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
            }
            XCTAssertTrue(first.contains(c))
            XCTAssertTrue(result.diagnostics.contains { $0.code == "enex.internalLinkUnresolved" && $0.location?.note == "1" })
        }
        let duplicate = try source([note(link(b, "AMBIGUOUS_TARGET"), guid: a), note("ONE", guid: b), note("TWO", guid: b)], name: "duplicate.enex")
        let result = try DocumentConverter().convert(.init(inputURL: duplicate, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        XCTAssertTrue(result.diagnostics.contains { $0.code == "enex.internalLinkAmbiguous" })
        let text = try String(contentsOf: result.documents[0].markdownFile, encoding: .utf8)
        XCTAssertFalse(text.contains("../000002/"))
        XCTAssertFalse(text.contains("../000003/"))
        let conflict = try ENEXReader.read(Data(("<en-export>" + note("TEXT", resources: "<guid>" + b + "</guid>", guid: a) + "</en-export>").utf8))
        XCTAssertEqual(ENEXNoteLinks(notes: conflict.notes).warnings[1]?.first?.code, "enex.noteIdentityInvalid")
        let titles = try source([note(link(c, "Unique target"), title: "Origin"), note("DESTINATION", title: "Unique target")], name: "titles.enex")
        let titleResult = try DocumentConverter().convert(.init(inputURL: titles, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: titleResult.outputDirectory) }
        XCTAssertTrue(try linkTargets(titleResult.documents[0].markdownFile).isEmpty)
        XCTAssertTrue(titleResult.diagnostics.contains { $0.code == "enex.internalLinkUnresolved" })
    }

    func testMissingOrMismatchedMediaKeepsOriginalAssetsAndSpecificDiagnostics() throws {
        let data = Data([1, 2, 3])
        let url = try source([note("<en-media hash=\"00000000000000000000000000000000\" type=\"image/png\" alt=\"MISSING_LABEL\"/>" + media(data, mime: "application/pdf", label: "MISMATCH_LABEL"), resources: resource(data, mime: "application/octet-stream", name: "raw.bin"))])
        let result = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.documents[0].assets.first)), data)
        XCTAssertTrue(Set(result.diagnostics.map(\.code)).isSuperset(of: ["enex.resourceMissing", "enex.resourceTypeMismatch"]))
        let text = try String(contentsOf: result.documents[0].markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("MISSING_LABEL"))
        XCTAssertTrue(text.contains("MISMATCH_LABEL"))
    }

    func testInvalidBase64TypeAndLateResourceFailurePublishNothing() throws {
        let invalid = [
            "<resource><data>AA$=</data><mime>application/octet-stream</mime></resource>",
            "<resource><data>AB==</data><mime>application/octet-stream</mime></resource>",
            "<resource><data>AQID</data><mime>image/png</mime></resource>",
            "<resource><data>AQID</data><mime>text/html;evil=path</mime></resource>",
            "<resource><data>JVBERi1iYWQ=</data><mime>application/pdf</mime></resource>"
        ]
        for (index, bad) in invalid.enumerated() {
            let url = try source([note("GOOD_FIRST"), note("BAD_SECOND", resources: bad)], name: "bad\(index).enex")
            let target = root.appendingPathComponent("bad-result\(index)")
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: url, destination: .directory(target))))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testAlternatesRecognitionSVGAndActiveAttachmentsRemainSafeFiles() throws {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>SVG_SCRIPT_MARKER</script></svg>".utf8)
        let alternate = Data([7, 8, 9])
        let extra = "<alternate-data encoding=\"base64\">" + alternate.base64EncodedString() + "</alternate-data><recognition>&lt;recoIndex&gt;OCR_SOURCE_MARKER&lt;/recoIndex&gt;</recognition>"
        let url = try source([note(media(svg, mime: "image/svg+xml", label: "SVG_REFERENCE"), resources: resource(svg, mime: "image/svg+xml", name: "active.svg", extra: extra))])
        let result = try DocumentConverter().convert(.init(inputURL: url, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let assets = result.documents[0].assets
        XCTAssertEqual(assets.map(\.pathExtension), ["bin", "bin", "txt"])
        XCTAssertEqual(try Data(contentsOf: assets[0]), svg)
        XCTAssertEqual(try Data(contentsOf: assets[1]), alternate)
        XCTAssertEqual(try String(contentsOf: assets[2], encoding: .utf8), "<recoIndex>OCR_SOURCE_MARKER</recoIndex>")
        XCTAssertTrue(result.diagnostics.contains { $0.code == "enex.resourceKeptAsBinary" })
        let text = try String(contentsOf: result.documents[0].markdownFile, encoding: .utf8)
        XCTAssertFalse(text.contains("<script>"))
        XCTAssertTrue(text.contains("attachments/resource-000001.bin"))
    }

    func testResourceCountPixelBudgetsAndCancellationAreAtomic() throws {
        let emptyResource = resource(Data(), mime: "application/octet-stream", name: "empty.bin")
        let countSource = try source([note("COUNT_BODY", resources: String(repeating: emptyResource, count: ENEXResources.maximumResourcesPerNote + 1))], name: "count.enex")
        let countTarget = root.appendingPathComponent("count-result")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: countSource, destination: .directory(countTarget))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: countTarget.path))
        func largePNG(_ value: CGFloat) throws -> Data {
            try autoreleasepool {
                let context = try XCTUnwrap(CGContext(data: nil, width: 4096, height: 4096, bitsPerComponent: 8,
                    bytesPerRow: 4096 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(red: value, green: 0, blue: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 4096, height: 4096))
                let image = try XCTUnwrap(context.makeImage())
                let data = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                return data as Data
            }
        }
        let resources = try (0..<4).map { try resource(largePNG(CGFloat($0) / 4), mime: "image/png", name: "large.png") }.joined()
        let pixelSource = try source([note("PIXEL_BODY", resources: resources)], name: "pixels.enex")
        let pixelTarget = root.appendingPathComponent("pixel-result")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: pixelSource, destination: .directory(pixelTarget)))) {
            XCTAssertTrue($0.localizedDescription.contains("pixel budget"), $0.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pixelTarget.path))
        let data = try image(.png)
        let cancelledSource = try source([note("FIRST", resources: resource(data, mime: "image/png", name: "first.png")), note("SECOND", resources: emptyResource)], name: "cancel.enex")
        let token = ConversionCancellationToken()
        let target = root.appendingPathComponent("cancel-result")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: cancelledSource, destination: .directory(target)), progress: { value in
            if value.unit == .note && value.completed == 1 { token.cancel() }
        }, cancellation: token)) { if case ConversionError.cancelled = $0 {} else { XCTFail("unexpected error: \($0)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testHashCollisionDescriptorsNeverSelectAnArbitraryResource() throws {
        let hash = "00000000000000000000000000000000"
        let first = ENEXResources.Resource(index: 1, mime: "application/octet-stream", hash: hash, data: Data([1]), displayName: "one", path: "attachments/one.bin", image: false, cid: "cid:one")
        let second = ENEXResources.Resource(index: 2, mime: "application/octet-stream", hash: hash, data: Data([2]), displayName: "two", path: "attachments/two.bin", image: false, cid: "cid:two")
        let resources = ENEXResources(records: [first, second], assetPaths: [], appendix: "", warnings: [])
        let node = try ENEXXML.parse("<en-note><en-media hash=\"" + hash + "\" type=\"application/octet-stream\" alt=\"COLLISION_LABEL\"/></en-note>", root: "en-note")
        let resolved = resources.media(try XCTUnwrap(node.children.first))
        XCTAssertEqual(resolved.warning?.code, "enex.resourceHashAmbiguous")
        XCTAssertFalse(resolved.html.contains("attachments/one.bin"))
        XCTAssertFalse(resolved.html.contains("attachments/two.bin"))
        XCTAssertTrue(resolved.html.contains("COLLISION_LABEL"))
    }
}
