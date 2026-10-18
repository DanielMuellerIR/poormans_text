import AppKit
import XCTest
@testable import PoorMansTextAppSupport
import PoorMansTextCore

@MainActor
final class ClipboardImportTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMT-ClipboardImport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("PMT-ClipboardImport-\(UUID())"))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    private func finish(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        var checks = 0
        repeat {
            checks += 1
            if !model.isConverting { return }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTFail("Clipboard conversion did not finish after \(checks) checks")
    }

    private func verifyText(_ text: String, markers: [String]) {
        for marker in markers { XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, text) }
        XCTAssertTrue(text.contains("https://example.com/path"), text)
        XCTAssertTrue(text.contains("- First item") || text.contains("-   First item"), text)
    }

    private func packageBytes(_ root: URL) throws -> [String: Data] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var bytes: [String: Data] = [:]
        for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            bytes[String(file.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: file)
        }
        XCTAssertFalse(bytes.isEmpty)
        return bytes
    }

    func testFormatPriorityAndImmutableSnapshot() throws {
        let pasteboard = board()
        pasteboard.setData(Data("RTFD".utf8), forType: .rtfd)
        pasteboard.setData(Data("RTF".utf8), forType: .rtf)
        pasteboard.setData(Data("<p>HTML</p>".utf8), forType: .html)
        let snapshot = try RichTextClipboard.Source.read(from: pasteboard)
        XCTAssertEqual(snapshot.kind, .flatRTFD)
        pasteboard.clearContents()
        pasteboard.setData(Data("RTF".utf8), forType: .rtf)
        pasteboard.setData(Data("<p>HTML</p>".utf8), forType: .html)
        XCTAssertEqual(try RichTextClipboard.Source.read(from: pasteboard).kind, .rtf)
        XCTAssertEqual(snapshot.data, Data("RTFD".utf8))
    }

    func testPasteReadsPromisedContentOnlyOnExplicitCommand() async throws {
        let pasteboard = board()
        let provider = ClipboardReadProbe()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.rtf])
        pasteboard.writeObjects([item])
        let model = AppModel(defaults: .isolatedForAppTest())
        model.reset()
        _ = model.acceptsNewDocuments
        XCTAssertEqual(provider.requests, 0)
        model.pasteRichText(from: pasteboard)
        try await finish(model)
        XCTAssertEqual(provider.requests, 1)
        XCTAssertNotNil(model.clipboardDraft)
        model.reset()
    }

    func testOversizedClipboardPayloadIsRejectedBeforeConversion() throws {
        let pasteboard = board()
        pasteboard.setData(Data(repeating: 32, count: RichTextClipboard.maximumSourceBytes + 1), forType: .rtf)
        XCTAssertThrowsError(try RichTextClipboard.Source.read(from: pasteboard)) { error in
            XCTAssertTrue(error.localizedDescription.contains("64 MiB"))
        }
    }

    func testEmptyPlainImageAndMultipleItemsAreExplained() throws {
        let pasteboard = board()
        let model = AppModel(defaults: .isolatedForAppTest())
        pasteboard.clearContents()
        model.pasteRichText(from: pasteboard)
        XCTAssertTrue(model.actionMessage?.contains("empty") == true)
        pasteboard.setString("literal plain text", forType: .string)
        model.pasteRichText(from: pasteboard)
        XCTAssertTrue(model.actionMessage?.contains("plain text only") == true)
        XCTAssertEqual(pasteboard.string(forType: .string), "literal plain text")
        pasteboard.clearContents()
        pasteboard.setData(Data([1]), forType: .png)
        XCTAssertThrowsError(try RichTextClipboard.Source.read(from: pasteboard))
        pasteboard.clearContents()
        let items = (0..<2).map { _ in let item = NSPasteboardItem(); item.setString("<p>item</p>", forType: .html); return item }
        pasteboard.writeObjects(items)
        XCTAssertThrowsError(try RichTextClipboard.Source.read(from: pasteboard)) { error in
            XCTAssertTrue(error.localizedDescription.contains("several items"))
        }
        XCTAssertTrue(model.acceptsNewDocuments)
    }

    func testBrokenPreferredFormatDoesNotSilentlyFallBack() async throws {
        let pasteboard = board()
        pasteboard.setData(Data("broken flat RTFD".utf8), forType: .rtfd)
        pasteboard.setData(Data(#"{\rtf1 FALLBACK}"#.utf8), forType: .rtf)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.pasteRichText(from: pasteboard)
        try await finish(model)
        guard case .failed(_, let message) = model.state else { return XCTFail("Broken RTFD was accepted") }
        XCTAssertTrue(message.contains("could not be read"), message)
        XCTAssertNil(model.clipboardDraft)
    }

    func testRealRTFRetainsTextListsLinksAndOriginalImageBytes() throws {
        let root = try workspace()
        let fixture = try FixtureFactory.createRichRTF(in: root)
        let bytes = try Data(contentsOf: fixture.fileURL)
        let result = try RichTextClipboard.convertDocument(.init(kind: .rtf, data: bytes))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        verifyText(try String(contentsOf: result.markdownFile, encoding: .utf8), markers: ["Start", "Purple text", "Second item"])
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), fixture.imageData)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.inputURL.path))
    }

    func testRTFDDraftPreviewAndPersistentAssetsUseCapturedSourceAndOptions() async throws {
        let root = try workspace()
        let fixture = try FixtureFactory.createRichRTFD(in: root)
        let original = try packageBytes(fixture.packageURL)
        let attributed = try XCTUnwrap(NSMutableAttributedString(rtfdFileWrapper: FileWrapper(url: fixture.packageURL), documentAttributes: nil))
        attributed.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: NSRange(location: 0, length: 5))
        let flat = try XCTUnwrap(attributed.rtfd(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]))
        let pasteboard = board()
        pasteboard.setData(flat, forType: .rtfd)
        let change = pasteboard.changeCount
        let model = AppModel(defaults: .isolatedForAppTest())
        model.frontmatter = true
        model.pasteRichText(from: pasteboard)
        try await finish(model)
        let temporary = try XCTUnwrap(model.selectedResult)
        XCTAssertNotNil(model.clipboardDraft)
        XCTAssertEqual(temporary.outputLifetime, .temporary)
        XCTAssertEqual(pasteboard.changeCount, change)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.inputURL.path))
        model.loadPreview()
        let deadline = Date().addingTimeInterval(10)
        while model.isLoadingPreview, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.preview?.text.contains("Second item") == true)
        let expected = try String(contentsOf: temporary.markdownFile, encoding: .utf8)
        pasteboard.clearContents(); pasteboard.setString("replacement must not be read", forType: .string)
        model.frontmatter = false
        let target = root.appendingPathComponent("Permanent")
        model.saveClipboardResult(to: target)
        try await finish(model)
        let saved = try XCTUnwrap(model.selectedResult)
        XCTAssertNil(model.clipboardDraft)
        XCTAssertEqual(saved.outputLifetime, .persistent)
        XCTAssertEqual(saved.outputDirectory, target)
        XCTAssertEqual(try String(contentsOf: saved.markdownFile, encoding: .utf8), expected)
        verifyText(expected, markers: ["Start", "Second item"])
        XCTAssertEqual(saved.assets.count, fixture.imageData.count)
        XCTAssertEqual(Set(try saved.assets.map { try Data(contentsOf: $0) }), Set(fixture.imageData))
        for asset in saved.assets { XCTAssertTrue(expected.contains("images/" + asset.lastPathComponent), expected) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.outputDirectory.path))
        XCTAssertEqual(try packageBytes(fixture.packageURL), original)
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement must not be read")
    }

    func testHTMLDataImagesAndMissingReferencesAreLocalAndDiagnosed() throws {
        let root = try workspace()
        let png = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
        let html = "<html><body><p style='color:red'>HTMLMarker <a href='https://example.com/path'>Link</a></p><ul><li>First item</li><li>Second item</li></ul><img alt='Embedded' src='data:image/png;base64,\(png.base64EncodedString())'><img alt='Remote' src='https://example.invalid/never-fetch.png'><img alt='Missing' src='file:///private/never-read.png'></body></html>"
        let source = root.appendingPathComponent("source.html")
        let bytes = Data(html.utf8)
        try bytes.write(to: source)
        let result = try RichTextClipboard.convertDocument(.init(kind: .html, data: bytes))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        verifyText(text, markers: ["HTMLMarker", "Second item", "Remote", "Missing"])
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), png)
        XCTAssertTrue(text.contains("https://example.invalid/never-fetch.png"), text)
        XCTAssertGreaterThanOrEqual(result.diagnostics.count, 3)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testHTMLServiceAndAppCopyHaveIdenticalOutputAndWarnings() async throws {
        let pasteboard = board(), output = board()
        pasteboard.setString("<p>HTMLClipboardMarker</p><ul><li>ListMarker</li></ul>", forType: .html)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.pasteRichText(from: pasteboard)
        try await finish(model)
        let temporary = try XCTUnwrap(model.selectedResult).outputDirectory
        model.copyMarkdown(to: output)
        guard case .copiedToClipboard(let actual) = model.state else { return XCTFail("Not copied") }
        let expected = try RichTextClipboard.convert(.read(from: pasteboard), options: model.conversionOptions)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(output.string(forType: .string), expected.markdown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        let serviceModel = AppModel(defaults: .isolatedForAppTest())
        let service = ServicesProvider(model: serviceModel, outputPasteboard: output)
        var error: NSString?
        service.convertRichTextToMarkdown(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        try await finish(serviceModel)
        XCTAssertEqual(output.string(forType: .string), expected.markdown)
    }

    func testExistingDestinationAndSaveCancellationKeepDraftAndFiles() async throws {
        let root = try workspace(), pasteboard = board()
        pasteboard.setData(Data(#"{\rtf1 KeptMarker}"#.utf8), forType: .rtf)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.pasteRichText(from: pasteboard)
        try await finish(model)
        let temporary = try XCTUnwrap(model.selectedResult).outputDirectory
        let existing = root.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        model.saveClipboardResult(to: existing)
        try await finish(model)
        XCTAssertNotNil(model.clipboardDraft)
        XCTAssertTrue(model.actionMessage?.contains("will not be overwritten") == true)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        let cancelled = root.appendingPathComponent("Cancelled")
        model.saveClipboardResult(to: cancelled)
        model.cancelConversion()
        try await finish(model)
        XCTAssertNotNil(model.clipboardDraft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        model.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testMissingPandocAndCancelledPasteLeaveClipboardUntouched() async throws {
        let pasteboard = board()
        let bytes = Data(#"{\rtf1 OriginalMarker}"#.utf8)
        pasteboard.setData(bytes, forType: .rtf)
        let change = pasteboard.changeCount
        let model = AppModel(defaults: .isolatedForAppTest())
        model.profilePandocExecutable = URL(fileURLWithPath: "/nonexistent-pmt-clipboard/pandoc")
        model.pasteRichText(from: pasteboard)
        try await finish(model)
        guard case .failed(_, let message) = model.state else { return XCTFail("Missing Pandoc accepted") }
        XCTAssertTrue(message.contains("Pandoc was not found"), message)
        model.profilePandocExecutable = nil
        model.pasteRichText(from: pasteboard)
        model.cancelConversion()
        try await finish(model)
        guard case .failed(_, let cancelled) = model.state else { return XCTFail("Cancellation ignored") }
        XCTAssertTrue(cancelled.contains("cancelled"), cancelled)
        XCTAssertNil(model.clipboardDraft)
        XCTAssertEqual(pasteboard.changeCount, change)
        XCTAssertEqual(pasteboard.data(forType: .rtf), bytes)
    }

    func testInvalidPastePreservesReadyDraftAndDiscardRemovesIt() async throws {
        let pasteboard = board()
        pasteboard.setData(Data(#"{\rtf1 ReadyMarker}"#.utf8), forType: .rtf)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.pasteRichText(from: pasteboard)
        try await finish(model)
        let result = try XCTUnwrap(model.selectedResult)
        pasteboard.clearContents()
        model.pasteRichText(from: pasteboard)
        XCTAssertEqual(model.selectedResult?.outputDirectory, result.outputDirectory)
        XCTAssertNotNil(model.clipboardDraft)
        model.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.outputDirectory.path))
    }

    func testNormalTerminationRemovesDraftButKeepsPersistentResult() async throws {
        let root = try workspace(), pasteboard = board()
        pasteboard.setData(Data(#"{\rtf1 TerminationMarker}"#.utf8), forType: .rtf)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.pasteRichText(from: pasteboard)
        try await finish(model)
        let temporary = try XCTUnwrap(model.selectedResult).outputDirectory
        model.prepareToTerminate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        model.pasteRichText(from: pasteboard)
        try await finish(model)
        let saved = root.appendingPathComponent("Kept")
        model.saveClipboardResult(to: saved)
        try await finish(model)
        model.prepareToTerminate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }
}

private final class ClipboardReadProbe: NSObject, NSPasteboardItemDataProvider {
    var requests = 0
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        requests += 1
        item.setData(Data(#"{\rtf1 ExplicitReadMarker}"#.utf8), forType: type)
    }
}
