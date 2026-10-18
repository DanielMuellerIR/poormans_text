import AppKit
import AppIntents
import Foundation
import XCTest
@testable import PoorMansTextAppSupport
@testable import PoorMansTextCore

final class AppCollectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTAppCollection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func source(package: Bool) throws -> URL {
        let input = root.appendingPathComponent(package ? "Export.mbox" : "Regular.mbox")
        let data = Data((1...3).map { index in
            "From sender@example.test Sun Oct 18 06:00:00 2026\nFrom: sender@example.test\nSubject: Duplicate title\nContent-Type: text/plain; charset=utf-8\n\nAPP_MESSAGE_\(index)\n\n"
        }.joined().utf8)
        if package {
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
            try data.write(to: input.appendingPathComponent("mbox"))
            try Data("DO_NOT_IMPORT".utf8).write(to: input.appendingPathComponent("ignored.eml"))
        } else { try data.write(to: input) }
        return input
    }

    @MainActor private func finished(_ model: AppModel) async throws -> ConversionResult {
        let deadline = Date().addingTimeInterval(10)
        while model.isConverting, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if case .succeeded(let result) = model.state { return result }
        if case .batchFinished(let items) = model.state, let result = items.first?.result { return result }
        throw NSError(domain: "AppCollectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "No collection result: \(model.state)"])
    }

    @MainActor func testBothFormsSelectCopyAndPreviewEachMessageAndOverview() async throws {
        for package in [false, true] {
            let input = try source(package: package)
            let model = AppModel(defaults: .isolatedForAppTest())
            model.conversionReport = true
            model.convert(input)
            let result = try await finished(model)
            XCTAssertTrue(result.isCollection)
            XCTAssertEqual(result.documents.count, 3)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            for index in [2, 1, 3] {
                model.selectCollectionDocument(index)
                XCTAssertEqual(model.selectedOutput?.markdownFile, result.documents[index - 1].markdownFile)
                model.copyMarkdown(to: board)
                XCTAssertEqual(board.string(forType: .string)?.components(separatedBy: "APP_MESSAGE_").count, 2)
                XCTAssertTrue(board.string(forType: .string)?.contains("APP_MESSAGE_\(index)") == true)
                model.loadPreview()
                let deadline = Date().addingTimeInterval(3)
                while model.isLoadingPreview, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(model.preview?.text.contains("APP_MESSAGE_\(index)") == true)
                XCTAssertEqual(model.preview?.matchesExpectedOutput, true)
            }
            model.selectCollectionDocument(nil)
            XCTAssertNil(model.preview)
            XCTAssertEqual(model.selectedOutput?.markdownFile, result.markdownFile)
            model.copyMarkdown(to: board)
            XCTAssertEqual(board.string(forType: .string)?.components(separatedBy: "Duplicate title").count, 4)
            model.selectCollectionDocument(999)
            XCTAssertNil(model.selectedDocumentIndex)
            XCTAssertNotNil(model.selectedResult?.reportFile)
            model.reset()
            XCTAssertNil(model.selectedDocumentIndex)
        }
    }

    @MainActor func testSelectedMessagePreviewResolvesItsOwnImagesInBothLayouts() async throws {
        let png = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
        let input = root.appendingPathComponent("Images.mbox")
        let message = "From sender@example.test Sun Oct 18 06:00:00 2026\nSubject: Image\nContent-Type: multipart/related; boundary=rel\n\n--rel\nContent-Type: text/html; charset=utf-8\n\n<p>IMAGE_MESSAGE</p><img src=\"cid:picture\">\n--rel\nContent-Type: image/png\nContent-ID: <picture>\nContent-Disposition: inline; filename=same.png\nContent-Transfer-Encoding: base64\n\n\(png.base64EncodedString())\n--rel--\n\n"
        try Data(message.utf8).write(to: input)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let destination = root.appendingPathComponent(layout.rawValue)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let model = AppModel(defaults: .isolatedForAppTest())
            model.outputLayout = layout; model.destinationFolder = destination
            model.convert(input)
            _ = try await finished(model)
            model.selectCollectionDocument(1)
            let selected = try XCTUnwrap(model.selectedOutput)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(selected.assets.first)), png)
            let assets = try PreviewAssets(outputDirectory: selected.outputDirectory, assets: selected.assets)
            let markdown = try String(contentsOf: selected.markdownFile, encoding: .utf8)
            let rendered = RenderedMarkdownPreview.render(markdown, assets: assets)
            XCTAssertEqual(rendered.unavailableImageCount, 0)
            XCTAssertTrue(rendered.html.contains("pmt-preview://"))
            XCTAssertTrue(markdown.contains("IMAGE_MESSAGE"))
        }
    }

    @MainActor func testFileServiceTreatsAppleMailPackageAsOneCollection() async throws {
        let input = try source(package: true)
        let model = AppModel(defaults: .isolatedForAppTest())
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([input as NSURL]))
        let provider = ServicesProvider(model: model, outputPasteboard: board)
        var error: NSString?
        provider.convertFilesToMarkdown(board, userData: nil, error: &error)
        XCTAssertNil(error)
        let result = try await finished(model)
        XCTAssertEqual(result.documents.count, 3)
    }

    func testShortcutConvertsBothFormsAndKeepsCompleteFolderReturn() async throws {
        for package in [false, true] {
            let input = try source(package: package)
            let original = try Data(contentsOf: package ? input.appendingPathComponent("mbox") : input)
            let intent = ConvertDocumentIntent()
            intent.document = IntentFile(fileURL: input)
            intent.destinationFolder = IntentFile(fileURL: root)
            intent.conversionReport = true
            intent.textbundle = true
            let value = try await intent.perform().value
            let output = try XCTUnwrap(value?.first.flatMap(URL.init(string:)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("text.md").path))
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: output.appendingPathComponent("conversion-report.json")))
            XCTAssertEqual(report.documents?.count, 3)
            XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
            XCTAssertEqual(try Data(contentsOf: package ? input.appendingPathComponent("mbox") : input), original)
        }
    }
}
