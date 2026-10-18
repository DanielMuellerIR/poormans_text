import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PoorMansTextAppSupport
import PoorMansTextCore

@MainActor
final class ClipboardImageTests: XCTestCase {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("PMT-ClipboardImage-\(UUID())"))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMT-ClipboardImage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func finish(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(60)
        repeat {
            if !model.isConverting { return }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTFail("Clipboard image conversion did not finish")
    }

    private func image(text: String = "ALPHA 7129", width: Int = 1600, height: Int = 900,
                       type: UTType = .png, transparent: Bool = false, orientation: Int = 1) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSColor.white.setFill()
        let margin: CGFloat = transparent ? 20 : 0
        NSBezierPath(rect: NSRect(x: margin, y: margin, width: CGFloat(width) - 2 * margin, height: CGFloat(height) - 2 * margin)).fill()
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(width) / 20), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: CGFloat(width) / 12, y: CGFloat(height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage), [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func convert(_ source: RichTextClipboard.Source, options: ConversionOptions = .init()) throws -> ConversionResult {
        let result = try RichTextClipboard.convertDocument(source, options: options)
        addTeardownBlock { try? FileManager.default.removeItem(at: result.outputDirectory) }
        return result
    }

    func testRichTextThenLosslessImagePriorityAndServiceCompatibility() throws {
        let pasteboard = board(), png = try image(), tiff = try image(type: .tiff)
        pasteboard.setData(tiff, forType: .tiff)
        pasteboard.setData(png, forType: .png)
        XCTAssertEqual(try RichTextClipboard.Source.read(from: pasteboard), .init(kind: .image(.png), data: png))
        XCTAssertNil(RichTextClipboard.Source(pasteboard: pasteboard))
        pasteboard.setData(Data("<p>Formatted selection</p>".utf8), forType: .html)
        XCTAssertEqual(try RichTextClipboard.Source.read(from: pasteboard).kind, .html)
        XCTAssertEqual(RichTextClipboard.Source(pasteboard: pasteboard)?.kind, .html)
        pasteboard.clearContents(); pasteboard.setData(tiff, forType: .tiff)
        XCTAssertEqual(try RichTextClipboard.Source.read(from: pasteboard).kind, .image(.tiff))
    }

    func testAllOfferedEncodedFormatsKeepBytesAndDetectedAssetExtension() throws {
        let pasteboard = board()
        for format in ClipboardImageFormat.allCases {
            let type = try XCTUnwrap(UTType(format.pasteboardType.rawValue))
            // ImageIO kann WebP lesen, aber nicht schreiben; kleines VP8-Fixture.
            let data: Data
            if format == .webp {
                data = Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")!
            } else {
                data = try image(type: type)
            }
            pasteboard.clearContents(); pasteboard.setData(data, forType: format.pasteboardType)
            let source = try RichTextClipboard.Source.read(from: pasteboard)
            XCTAssertEqual(source.kind, .image(format))
            let result = try convert(source, options: .init(imageTextRecognition: .disabled))
            XCTAssertEqual(result.format, .image)
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: result.assets[0]), data, format.rawValue)
            XCTAssertEqual(result.assets[0].pathExtension, format.fileExtension)
        }
    }

    func testActualPNGFixtureHasIndependentOCRMarkersAndUnchangedTransparentRetinaAsset() throws {
        let root = try workspace(), data = try image(text: "ALPHA 7129\nBETA 4386", transparent: true)
        let input = root.appendingPathComponent("source.png")
        try data.write(to: input)
        let pasteboard = board(); pasteboard.setData(try Data(contentsOf: input), forType: .png)
        let captured = try RichTextClipboard.Source.read(from: pasteboard)
        pasteboard.clearContents(); pasteboard.setString("replacement", forType: .string)
        try FileManager.default.removeItem(at: input)
        let result = try convert(captured)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for marker in ["ALPHA", "7129", "BETA", "4386"] {
            XCTAssertEqual(markdown.components(separatedBy: marker).count - 1, 1, markdown)
        }
        XCTAssertEqual(try Data(contentsOf: result.assets[0]), data)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.assets[0] as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1600)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 900)
        XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true)
        XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Double ?? 0, 144, accuracy: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.inputURL.path))
    }

    func testOrientationMetadataIsPreservedAndOCRUsesIt() throws {
        let data = try image(text: "ROTATION 8164", type: .tiff, orientation: 6)
        let result = try convert(.init(kind: .image(.tiff), data: data))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.assets[0] as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(try Data(contentsOf: result.assets[0]), data)
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("ROTATION"), text)
        XCTAssertTrue(text.contains("8164"), text)
    }

    func testLargeImageKeepsFullPixelsAndReportsOnlyOCRDownscaling() throws {
        let data = try image(text: "LARGE 9531", width: 5000, height: 4000)
        let result = try convert(.init(kind: .image(.png), data: data))
        XCTAssertEqual(try Data(contentsOf: result.assets[0]), data)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "image.ocrDownscaled" })
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("LARGE"), text); XCTAssertTrue(text.contains("9531"), text)
    }

    func testImageTextCopyOmitsDeadAssetReferenceAndCleansDraft() async throws {
        let pasteboard = board(); pasteboard.setData(try image(), forType: .png)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.pasteRichText(from: pasteboard); try await finish(model)
        let path = try XCTUnwrap(model.selectedResult?.outputDirectory)
        model.copyMarkdown(to: pasteboard)
        let text = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(text.contains("ALPHA")); XCTAssertTrue(text.contains("7129"))
        XCTAssertFalse(text.contains("![")); XCTAssertFalse(text.contains("images/image01"))
        guard case .copiedToClipboard(let outcome) = model.state else { return XCTFail("Text not copied") }
        XCTAssertTrue(outcome.warnings.contains { $0.contains("image was omitted") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testImageTextCopyInTextbundleOmitsAssetAndNoOCRKeepsDraftAndClipboard() async throws {
        let pasteboard = board(), model = AppModel(defaults: .isolatedForAppTest())
        let data = try image()
        model.outputLayout = .textbundle
        pasteboard.setData(data, forType: .png)
        model.pasteRichText(from: pasteboard); try await finish(model)
        model.copyMarkdown(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "ALPHA 7129")
        model.reset(); model.imageTextRecognition = .disabled
        pasteboard.clearContents(); pasteboard.setData(data, forType: .png)
        model.pasteRichText(from: pasteboard); try await finish(model)
        let draft = try XCTUnwrap(model.clipboardDraft), change = pasteboard.changeCount
        model.copyMarkdown(to: pasteboard)
        XCTAssertTrue(model.clipboardDraft === draft)
        XCTAssertEqual(pasteboard.changeCount, change)
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        XCTAssertTrue(model.actionMessage?.contains("No recognized text") == true)
        model.reset(); draft.discard()
    }

    func testPromisedImageIsReadOnlyOnExplicitPasteAndClipboardChangeIsRejected() async throws {
        let pasteboard = board(), provider = ImageReadProbe(data: try image())
        let item = NSPasteboardItem(); item.setDataProvider(provider, forTypes: [.png])
        pasteboard.writeObjects([item])
        let model = AppModel(defaults: .isolatedForAppTest())
        model.reset(); _ = model.acceptsNewDocuments
        XCTAssertEqual(provider.requests, 0)
        model.pasteRichText(from: pasteboard); try await finish(model)
        XCTAssertEqual(provider.requests, 1)
        XCTAssertNotNil(model.clipboardDraft)
        model.reset()
        let changing = ImageReadProbe(data: try image(), changesClipboard: true)
        let changingItem = NSPasteboardItem(); changingItem.setDataProvider(changing, forTypes: [.png])
        pasteboard.clearContents(); pasteboard.writeObjects([changingItem])
        XCTAssertThrowsError(try RichTextClipboard.Source.read(from: pasteboard))
        XCTAssertNil(model.clipboardDraft)
    }

    func testProfileOptionsAreCapturedForPreviewAndPersistentSave() async throws {
        let root = try workspace(), store = ConversionProfileStore(directory: root.appendingPathComponent("profiles"))
        try store.save(ConversionProfile(name: "Image archive", options: .init(imageTextRecognition: .disabled, frontmatter: true, outputLayout: .textbundle, ocrMethod: .structured)))
        let model = AppModel(defaults: .isolatedForAppTest(), profileStore: store)
        try model.selectProfile(named: "Image archive")
        let data = try image(), pasteboard = board(); pasteboard.setData(data, forType: .png)
        model.pasteRichText(from: pasteboard); try await finish(model)
        let temporary = try XCTUnwrap(model.selectedResult), draft = try XCTUnwrap(model.clipboardDraft)
        XCTAssertEqual(draft.options.ocrMethod, .structured)
        XCTAssertEqual(draft.options.imageTextRecognition, .disabled)
        let text = try String(contentsOf: temporary.markdownFile, encoding: .utf8)
        XCTAssertTrue(draft.options.frontmatter); XCTAssertFalse(text.contains("ALPHA"))
        model.loadPreview()
        let deadline = Date().addingTimeInterval(30)
        while model.isLoadingPreview && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.preview?.text.contains("assets/image01.png") == true)
        pasteboard.clearContents(); pasteboard.setString("new clipboard", forType: .string)
        model.imageTextRecognition = .enabled; model.outputLayout = .markdownFolder; model.frontmatter = false
        let destination = root.appendingPathComponent("archive.textbundle")
        model.saveClipboardResult(to: destination); try await finish(model)
        let saved = try XCTUnwrap(model.selectedResult)
        XCTAssertEqual(saved.outputLifetime, .persistent)
        XCTAssertEqual(try String(contentsOf: saved.markdownFile, encoding: .utf8), text)
        XCTAssertEqual(try Data(contentsOf: saved.assets[0]), data)
        model.reset()
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.assets[0].path))
        draft.discard()
    }

    func testStructuredOCRIsUsedOnClipboardImage() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Structured OCR needs macOS 26") }
        let result = try convert(.init(kind: .image(.png), data: image(text: "STRUCTURED 6152")), options: .init(ocrMethod: .structured))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "STRUCTURED").count - 1, 1, text)
        XCTAssertEqual(text.components(separatedBy: "6152").count - 1, 1, text)
    }

    func testBrokenPreferredImageOversizeAndFileURLsNeverFallBack() throws {
        let pasteboard = board()
        pasteboard.setData(Data("broken PNG".utf8), forType: .png)
        pasteboard.setData(try image(type: .tiff), forType: .tiff)
        let source = try RichTextClipboard.Source.read(from: pasteboard)
        XCTAssertEqual(source.kind, .image(.png))
        XCTAssertThrowsError(try convert(source))
        pasteboard.clearContents(); pasteboard.setData(Data(repeating: 0, count: RichTextClipboard.maximumSourceBytes + 1), forType: .png)
        XCTAssertThrowsError(try RichTextClipboard.Source.read(from: pasteboard))
        pasteboard.clearContents(); pasteboard.setString("file:///does/not/authorize.png", forType: .fileURL)
        XCTAssertThrowsError(try RichTextClipboard.Source.read(from: pasteboard))
        XCTAssertThrowsError(try convert(.init(kind: .image(.png), data: Data("<p>HTML MUST NOT RUN</p>".utf8))))
    }

    func testDestinationCollisionAndCancellationKeepDraftAndExistingOutput() async throws {
        let root = try workspace(), pasteboard = board(), model = AppModel(defaults: .isolatedForAppTest())
        pasteboard.setData(try image(), forType: .png)
        model.pasteRichText(from: pasteboard); try await finish(model)
        let draft = try XCTUnwrap(model.clipboardDraft), temporary = draft.result.outputDirectory
        let destination = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("sentinel")
        try Data("KEEP".utf8).write(to: sentinel)
        model.saveClipboardResult(to: destination); try await finish(model)
        XCTAssertTrue(model.clipboardDraft === draft)
        XCTAssertTrue(model.actionMessage?.contains("will not be overwritten") == true)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "KEEP")
        let token = ConversionCancellationToken(); token.cancel()
        let cancelled = root.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try RichTextClipboard.convertDocument(draft.source, destination: .directory(cancelled), cancellation: token))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        model.reset(); draft.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }
}

private final class ImageReadProbe: NSObject, NSPasteboardItemDataProvider {
    let data: Data
    let changesClipboard: Bool
    var requests = 0
    init(data: Data, changesClipboard: Bool = false) { self.data = data; self.changesClipboard = changesClipboard }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        requests += 1
        item.setData(data, forType: type)
        if changesClipboard { pasteboard?.clearContents() }
    }
}
