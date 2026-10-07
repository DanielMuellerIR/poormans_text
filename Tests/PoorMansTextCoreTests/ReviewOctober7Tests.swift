import AppKit
import CoreText
import PDFKit
import XCTest
@testable import PoorMansTextCore

final class ReviewOctober7Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PoorMansTextReview7-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStagingIsPrivateUntilPublicationAndIsRemovedOnCancellation() throws {
        let source = root.appendingPathComponent("private.csv")
        let bytes = Data("Name,Value\nCONFIDENTIAL,42\n".utf8)
        try bytes.write(to: source)
        for cancel in [false, true] {
            let token = ConversionCancellationToken()
            let observations = PermissionObservations()
            let parent = try XCTUnwrap(root)
            let target = parent.appendingPathComponent(cancel ? "cancelled" : "complete")
            let convert = {
                try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(target)),
                    progress: { event in
                        guard event.phase == .converting || event.phase == .publishing else { return }
                        let stages = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
                        for stage in stages where stage.lastPathComponent.hasPrefix(".poormans-text-") {
                            let attributes = try? FileManager.default.attributesOfItem(atPath: stage.path)
                            observations.append((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1)
                        }
                        if cancel, event.phase == .publishing { token.cancel() }
                    }, cancellation: token)
            }
            if cancel { XCTAssertThrowsError(try convert()) } else { _ = try convert() }
            XCTAssertGreaterThanOrEqual(observations.values.count, 2)
            XCTAssertEqual(Set(observations.values), [0o700])
            XCTAssertEqual(FileManager.default.fileExists(atPath: target.path), !cancel)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".poormans-text-") })
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testHTMLImageCharacterReferencesResolveWithoutChangingSources() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
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

    func testBooleanFormulaWithoutCachedValueStaysEmptyAndWarns() throws {
        let sheet = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="b"><f>1=1</f></c><c r="B1" t="b"><f>1=1</f><v/></c><c r="C1" t="b"><v>0</v></c><c r="D1" t="b"><v>1</v></c></row></sheetData></worksheet>"#
        let source = root.appendingPathComponent("boolean.xlsx")
        let bytes = try ZIPFixtureBuilder.xlsxPackage(firstSheetXML: sheet, secondSheetXML: #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>"#)
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "FALSE").count - 1, 1, markdown)
        XCTAssertEqual(markdown.components(separatedBy: "TRUE").count - 1, 1, markdown)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "spreadsheet.formulaResultMissing" })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testInlineHTMLDoesNotExposeMarkdownExamplesAsLinks() throws {
        let markdown = #"Text <span title="[x](old.png)">text</span> <!-- [x](old.png) --> [real](old.png)"#
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: markdown, mapping: ["old.png": "new.png"]),
            #"Text <span title="[x](old.png)">text</span> <!-- [x](old.png) --> [real](new.png)"#)
    }

    func testListThenQuoteFenceKeepsItsLiteralLinks() throws {
        let markdown = "- > ~~~\n  > [literal](old.png)\n  > ~~~\n\n[real](old.png)"
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: markdown, mapping: ["old.png": "new.png"]),
            "- > ~~~\n  > [literal](old.png)\n  > ~~~\n\n[real](new.png)")
    }

    func testHTMLImageBudgetCountsEveryPhysicalCopyAndKeepsRepeatedReferencesCheap() throws {
        let png = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
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

    func testMalformedNestedLinkDestinationsAreLinearAndCancellable() throws {
        let input = String(repeating: "[x](", count: 40_000) + "\n\n[real](old.png)"
        var checks = 0
        let output = try MarkdownLinkTargetRewriter.replacing(in: input, mapping: ["old.png": "new.png"], checking: { checks += 1 })
        XCTAssertEqual(output, String(repeating: "[x](", count: 40_000) + "\n\n[real](new.png)")
        XCTAssertGreaterThan(checks, 100)
        enum Stopped: Error { case cancelled }
        checks = 0
        XCTAssertThrowsError(try MarkdownLinkTargetRewriter.replacing(in: input, mapping: ["old.png": "new.png"], checking: {
            checks += 1
            if checks == 20 { throw Stopped.cancelled }
        }))
        XCTAssertEqual(checks, 20)
    }

    func testMixedContainerOrderProtectsCodeAndHTMLAndEndsAtItsOwnBoundary() {
        for opener in ["~~~", "<pre>"] {
            let close = opener == "~~~" ? "~~~" : "</pre>"
            for (prefix, continuation) in [("- > - > ", "  >   > "), ("> - > - ", ">   >   ")] {
                let input = prefix + opener + "\n" + continuation + "[literal](old.png)\n" + continuation + close + "\n\n[real](old.png)"
                XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: input, mapping: ["old.png": "new.png"]),
                    input.replacingOccurrences(of: "[real](old.png)", with: "[real](new.png)"))
            }
        }
        let unclosed = "- > ~~~\n  > [literal](old.png)\n\n[real](old.png)"
        XCTAssertTrue(MarkdownLinkTargetRewriter.replacing(in: unclosed, mapping: ["old.png": "new.png"]).hasSuffix("[real](new.png)"))
    }

    func testRTFMetadataUnicodeFallbackIsScopedToItsGroup() {
        let rtf = #"{\rtf1\ansi{\info{\title {\uc0\u945}{\u946?}}}Text}"#
        XCTAssertEqual(RTFInfoParser.parse(Data(rtf.utf8)).title, "αβ")
    }

    func testMasterDeletedRevisionTextDoesNotBecomeCurrentContent() throws {
        let content = #"<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:tracked-changes><text:changed-region text:id="old"><text:deletion><text:p>DELETEDTOKEN</text:p></text:deletion></text:changed-region></text:tracked-changes><text:p>CURRENTTOKEN</text:p></office:text></office:body></office:document-content>"#
        let bytes = try ZIPFixtureBuilder.odmPackage(contentXML: content)
        let source = root.appendingPathComponent("revision.odm")
        try bytes.write(to: source)
        let converter = DocumentConverter()
        XCTAssertTrue(try converter.inspect(source).expectedWarnings.contains { $0.code == "openDocument.changesNotPreserved" })
        let result = try converter.convert(ConversionRequest(inputURL: source))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertFalse(text.contains("DELETEDTOKEN"), text)
        XCTAssertEqual(text.components(separatedBy: "CURRENTTOKEN").count - 1, 1)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "openDocument.changesNotPreserved" })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testPrefixedFictionBookRootConvertsWithoutSourceChanges() throws {
        let xml = #"<fb:FictionBook xmlns:fb="http://www.gribuser.ru/xml/fictionbook/2.0"><fb:description><fb:title-info><fb:book-title>Prefix title</fb:book-title></fb:title-info></fb:description><fb:body><fb:section><fb:p>PREFIXTOKEN</fb:p></fb:section></fb:body></fb:FictionBook>"#
        let bytes = Data(xml.utf8)
        let source = root.appendingPathComponent("prefix.fb2")
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("PREFIXTOKEN"))
        XCTAssertEqual(result.metadata.title, "Prefix title")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let fake = root.appendingPathComponent("fake.fb2")
        try Data(#"<!-- <FictionBook> --><wrong/>"#.utf8).write(to: fake)
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: fake))
    }

    func testRotatedGlyphOrderAndFallbackOCRKeepEachSentenceOnce() throws {
        let source = root.appendingPathComponent("rotated-text.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(gray: 1, alpha: 1); context.fill(box)
        context.setFillColor(gray: 0, alpha: 1)
        context.translateBy(x: 570, y: 700); context.rotate(by: .pi)
        for (index, text) in ["Alpha sentence with twelve apples.", "Beta sentence with seven trees."].enumerated() {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 20, y: CGFloat(index * 55))
            let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), context)
        }
        context.endPDFPage(); context.closePDF()
        let before = try Data(contentsOf: source)
        let page = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0))
        XCTAssertEqual(page.rotation, 0)
        let reference = try XCTUnwrap(page.string)
        XCTAssertEqual(try PDFTextLayout.lines(on: page).map(\.text).joined(separator: "\n"), reference)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
            options: ConversionOptions(pdfTextRecognition: .always, ocrLanguages: ["en"])))
        let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for sentence in ["Alpha sentence with twelve apples.", "Beta sentence with seven trees."] {
            XCTAssertEqual(output.components(separatedBy: sentence).count - 1, 1, output)
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testFallbackOCRRetainsAnEqualSentenceAtAnotherPosition() throws {
        let sentence = "Repeated sentence with twelve apples."
        func draw(_ context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat) {
            context.textMatrix = .identity; context.textPosition = CGPoint(x: x, y: y)
            context.setFillColor(gray: 0, alpha: 1)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: sentence, attributes:
                [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil)])), context)
        }
        let raster = try XCTUnwrap(CGContext(data: nil, width: 1500, height: 180,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        raster.setFillColor(gray: 1, alpha: 1); raster.fill(CGRect(x: 0, y: 0, width: 1500, height: 180))
        draw(raster, x: 30, y: 70, size: 65)
        let image = try XCTUnwrap(raster.makeImage())
        let source = root.appendingPathComponent("repeat-fallback.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        draw(context, x: 30, y: 650, size: 24)
        context.draw(image, in: CGRect(x: 30, y: 200, width: 550, height: 66))
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        XCTAssertTrue(document.write(to: source))
        let before = try Data(contentsOf: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
            options: ConversionOptions(pdfTextRecognition: .always, ocrLanguages: ["en"])))
        let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(output.components(separatedBy: sentence).count - 1, 2, output)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "pdf.layoutFallback" })
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testCodeMarkersCannotHideSubsequentInlineHTMLFromTheScanner() {
        let input = #"`<!--` <span title="[x](old.png)">ok</span> --> [real](old.png)"#
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: input, mapping: ["old.png": "new.png"]),
            input.replacingOccurrences(of: "[real](old.png)", with: "[real](new.png)"))
        let container = "- > text\n  > ~~~\n> [real](old.png)"
        XCTAssertEqual(MarkdownLinkTargetRewriter.replacing(in: container, mapping: ["old.png": "new.png"]),
            container.replacingOccurrences(of: "[real](old.png)", with: "[real](new.png)"))
    }

    private final class PermissionObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int] = []
        func append(_ value: Int) { lock.withLock { storage.append(value) } }
        var values: [Int] { lock.withLock { storage } }
    }
}
