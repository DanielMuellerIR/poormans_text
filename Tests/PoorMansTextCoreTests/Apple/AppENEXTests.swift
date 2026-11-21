import AppKit
import AppIntents
import CoreGraphics
import CryptoKit
import XCTest
@testable import PoorMansTextAppSupport
@testable import PoorMansTextCore

final class AppENEXTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTAppENEX-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func source() throws -> (URL, Data) {
        let png = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
        let hash = Insecure.MD5.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let notes = (1...3).map { index in
            """
            <note><title>Duplicate title</title><content><![CDATA[<en-note><p>ENEX_APP_BODY_\(index)</p><en-media hash="\(hash)" type="image/png"/><a href="evernote:///view/1/s1/33333333-3333-4333-8333-333333333333/33333333-3333-4333-8333-333333333333/">UNRESOLVED_\(index)</a></en-note>]]></content><created>20261016T120000Z</created><tag>Tag \(index)</tag><resource><data encoding="base64">\(png.base64EncodedString())</data><mime>image/png</mime><resource-attributes><file-name>../../same.command</file-name></resource-attributes></resource></note>
            """
        }.joined()
        let input = root.appendingPathComponent("notes.enex")
        try Data(("<en-export>" + notes + "</en-export>").utf8).write(to: input)
        return (input, png)
    }
    @MainActor private func finished(_ model: AppModel) async throws -> ConversionResult {
        let deadline = Date().addingTimeInterval(15)
        while model.isConverting, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if case .succeeded(let result) = model.state { return result }
        if case .batchFinished(let items) = model.state, let result = items.first?.result { return result }
        throw NSError(domain: "AppENEXTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "No ENEX result: \(model.state)"])
    }
    @MainActor func testProfileNoteSelectionCopyPreviewAndCompleteReportInBothLayouts() async throws {
        let (input, png) = try source(), original = try Data(contentsOf: input)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let store = ConversionProfileStore(directory: root.appendingPathComponent("profiles-" + layout.rawValue))
            let model = AppModel(defaults: .isolatedForAppTest(), profileStore: store)
            model.outputLayout = layout; model.frontmatter = true; model.conversionReport = true
            try model.saveProfile(named: "Notes")
            model.frontmatter = false
            try model.selectProfile(named: "Notes")
            model.destinationFolder = root.appendingPathComponent(layout.rawValue)
            try FileManager.default.createDirectory(at: model.destinationFolder!, withIntermediateDirectories: false)
            model.convert(input)
            let result = try await finished(model)
            XCTAssertEqual(result.format, .enex); XCTAssertEqual(result.documents.count, 3)
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            for index in [3, 1, 2] {
                model.selectCollectionDocument(index)
                let selected = try XCTUnwrap(model.selectedOutput)
                XCTAssertEqual(selected.metadata.title, "Duplicate title")
                XCTAssertEqual(selected.metadata.keywords, ["Tag \(index)"])
                XCTAssertTrue(selected.diagnostics.contains { $0.location?.note == String(index) })
                XCTAssertFalse(selected.diagnostics.contains { $0.location?.note != String(index) })
                model.copyMarkdown(to: board)
                let text = try XCTUnwrap(board.string(forType: .string))
                XCTAssertTrue(text.hasPrefix("---\n")); XCTAssertEqual(text.components(separatedBy: "ENEX_APP_BODY_").count - 1, 1)
                XCTAssertTrue(text.contains("ENEX_APP_BODY_\(index)"))
                model.loadPreview()
                let deadline = Date().addingTimeInterval(3)
                while model.isLoadingPreview, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(model.preview?.matchesExpectedOutput, true)
                let assets = try PreviewAssets(outputDirectory: selected.outputDirectory, assets: selected.assets)
                XCTAssertEqual(RenderedMarkdownPreview.render(text, assets: assets).unavailableImageCount, 0)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(selected.assets.first)), png)
            }
            model.selectCollectionDocument(nil)
            XCTAssertNil(model.preview); XCTAssertEqual(model.selectedOutput?.markdownFile, result.markdownFile)
            model.copyMarkdown(to: board)
            XCTAssertEqual(board.string(forType: .string)?.components(separatedBy: "Duplicate title").count, 4)
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
            XCTAssertEqual(report.documents?.count, 3); XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }
    @MainActor func testFileServiceAndShortcutRetainAllNotesAndAssets() async throws {
        let (input, _) = try source()
        let model = AppModel(defaults: .isolatedForAppTest())
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([input as NSURL]))
        var error: NSString?
        ServicesProvider(model: model, outputPasteboard: board).convertFilesToMarkdown(board, userData: nil, error: &error)
        XCTAssertNil(error)
        let result = try await finished(model)
        XCTAssertEqual(result.documents.count, 3); XCTAssertEqual(result.documents.map { $0.assets.count }, [2, 2, 2])
        let intent = ConvertDocumentIntent()
        intent.document = IntentFile(fileURL: input); intent.destinationFolder = IntentFile(fileURL: root)
        intent.textbundle = true; intent.frontmatter = true; intent.conversionReport = true
        let value = try await intent.perform().value
        let output = try XCTUnwrap(value?.first.flatMap(URL.init(string:)))
        let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: output.appendingPathComponent("conversion-report.json")))
        XCTAssertEqual(report.documents?.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("text.md").path))
    }
    func testProfileShortcutReturnsCompleteENEXCollectionWithInheritedOptions() async throws {
        let (input, _) = try source()
        let store = ConversionProfileStore(directory: root.appendingPathComponent("shortcut-profiles"))
        try store.save(ConversionProfile(name: "ENEX", options: .init(frontmatter: true, outputLayout: .textbundle, sourceMapping: true, conversionReport: true)))
        var intent = ConvertWithProfileIntent()
        intent.profileStoreOverride = store; intent.profile = ShortcutProfile(name: "ENEX")
        intent.document = IntentFile(fileURL: input); intent.destinationFolder = IntentFile(fileURL: root)
        let value = try await intent.perform().value
        let output = try XCTUnwrap(value?.first.flatMap(URL.init(string:)))
        XCTAssertEqual(output.pathExtension, "textbundle")
        let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: output.appendingPathComponent("conversion-report.json")))
        XCTAssertEqual(report.documents?.count, 3); XCTAssertTrue(report.options.frontmatter)
        XCTAssertEqual(report.options.outputLayout, .textbundle)
        for index in 1...3 {
            let file = output.appendingPathComponent(String(format: "assets/documents/%06d/notes.md", index))
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.hasPrefix("---\n")); XCTAssertTrue(text.contains("ENEX_APP_BODY_\(index)"))
        }
    }
    func testAttachmentSnapshotsPreviewPDFTextAndImagesButRejectSymlinkAndUnregisteredFiles() throws {
        let (input, png) = try source()
        let result = try DocumentConverter().convert(.init(inputURL: input, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let note = result.documents[0], directory = note.markdownFile.deletingLastPathComponent()
        let text = directory.appendingPathComponent("test.txt"), pdf = directory.appendingPathComponent("test.pdf"), binary = directory.appendingPathComponent("test.bin")
        try Data("LOCAL_ATTACHMENT_TEXT".utf8).write(to: text); try Data("<svg><script>active</script></svg>".utf8).write(to: binary)
        let data = NSMutableData(); let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 40, height: 40)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(box); context.endPDFPage() }
        context.closePDF(); try (data as Data).write(to: pdf)
        let assets = try PreviewAssets(outputDirectory: directory, assets: note.assets + [text, pdf, binary])
        if case .text(let value, let truncated) = try assets.previewFile("test.txt") { XCTAssertEqual(value, "LOCAL_ATTACHMENT_TEXT"); XCTAssertFalse(truncated) } else { XCTFail("Text preview missing") }
        if case .pdf(let bytes, let count) = try assets.previewFile("test.pdf") { XCTAssertEqual(count, 2); XCTAssertNotNil(NSImage(data: bytes)) } else { XCTFail("PDF preview missing") }
        if case .image(let bytes) = try assets.previewFile("attachments/resource-000001.png") { XCTAssertNotNil(NSImage(data: bytes)) } else { XCTFail("Image preview missing") }
        if case .unsupported = try assets.previewFile("test.bin") {} else { XCTFail("Active type previewed") }
        XCTAssertThrowsError(try assets.previewFile("../test.txt")); XCTAssertThrowsError(try assets.previewFile("unknown.txt"))
        try FileManager.default.removeItem(at: text)
        try FileManager.default.createSymbolicLink(at: text, withDestinationURL: input)
        XCTAssertThrowsError(try assets.previewFile("test.txt"))
        XCTAssertEqual(try Data(contentsOf: note.assets[0]), png)
    }
    func testENEXCatalogReportsActualPandocRequirement() throws {
        let catalog = DocumentConverter().formatCatalog(resolver: .init(pandocExecutable: URL(fileURLWithPath: "/nonexistent/pandoc")))
        let item = try XCTUnwrap(catalog.first { $0.format.format == .enex })
        XCTAssertEqual(item.format.fileExtensions, ["enex"]); XCTAssertEqual(item.format.containerKinds, [.file])
        XCTAssertFalse(item.isAvailable); XCTAssertEqual(item.missingTools, [.pandoc])
    }
}
