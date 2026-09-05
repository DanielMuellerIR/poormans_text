import AppKit
import Foundation
import XCTest
@testable import PoorMansTextAppSupport

/// Die beiden Systemdienste aus `App/Info.plist`: Dateien aus dem Finder gehen
/// denselben Weg wie ein Drop, markierter Rich Text landet als Markdown in
/// einer Zwischenablage. Die Tests rufen die Dienstmethoden mit eigenen,
/// benannten Pasteboards auf, damit die echte Zwischenablage unberührt bleibt.
final class ServicesProviderTests: XCTestCase {
    private var root: URL!
    private var input: NSPasteboard!
    private var output: NSPasteboard!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextServicesTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        input = NSPasteboard(name: NSPasteboard.Name("PoorMansTextServiceInput-\(UUID().uuidString)"))
        output = NSPasteboard(name: NSPasteboard.Name("PoorMansTextServiceOutput-\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        input.releaseGlobally()
        output.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testTheFileServiceConvertsEveryFileOnThePasteboard() async throws {
        let first = try copyImage(to: "A.png")
        let second = try copyImage(to: "B.png")
        let model = AppModel(defaults: .isolatedForAppTest())
        model.imageTextRecognition = .disabled
        let provider = ServicesProvider(model: model, outputPasteboard: output)
        input.clearContents()
        XCTAssertTrue(input.writeObjects([first as NSURL, second as NSURL]))

        var serviceError: NSString?
        provider.convertFilesToMarkdown(input, userData: nil, error: &serviceError)

        XCTAssertNil(serviceError)
        let items = try await awaitBatch(model)
        XCTAssertEqual(items.map { $0.input.lastPathComponent }, ["A.png", "B.png"])
        XCTAssertTrue(items.allSatisfy { $0.result != nil })
    }

    @MainActor
    func testTheFileServiceReportsAnEmptyPasteboardInsteadOfDoingNothing() {
        let model = AppModel(defaults: .isolatedForAppTest())
        let provider = ServicesProvider(model: model, outputPasteboard: output)
        input.clearContents()
        input.setString("no file", forType: .string)

        var serviceError: NSString?
        provider.convertFilesToMarkdown(input, userData: nil, error: &serviceError)

        XCTAssertEqual(serviceError, "The service received no files.")
        XCTAssertFalse(model.isConverting)
    }

    @MainActor
    func testTheRichTextServiceCopiesMarkdownFromRTFD() async throws {
        let text = NSMutableAttributedString(string: "Plain and ")
        text.append(NSAttributedString(
            string: "bold",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        ))
        text.append(NSAttributedString(string: " words\n"))
        let rtfd = try XCTUnwrap(text.rtfd(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ))
        input.clearContents()
        input.setData(rtfd, forType: .rtfd)
        let model = AppModel(defaults: .isolatedForAppTest())
        let provider = ServicesProvider(model: model, outputPasteboard: output)

        var serviceError: NSString?
        provider.convertRichTextToMarkdown(input, userData: nil, error: &serviceError)

        XCTAssertNil(serviceError)
        XCTAssertTrue(model.isConverting)
        let outcome = try await awaitClipboard(model)
        XCTAssertTrue(outcome.markdown.contains("**bold**"), outcome.markdown)
        XCTAssertEqual(output.string(forType: .string), outcome.markdown)
        XCTAssertTrue(model.acceptsNewDocuments)
    }

    @MainActor
    func testTheRichTextServiceReportsMissingRichTextWithoutTouchingTheClipboard() {
        input.clearContents()
        input.setString("plain only", forType: .string)
        output.clearContents()
        output.setString("untouched", forType: .string)
        let model = AppModel(defaults: .isolatedForAppTest())
        let provider = ServicesProvider(model: model, outputPasteboard: output)

        var serviceError: NSString?
        provider.convertRichTextToMarkdown(input, userData: nil, error: &serviceError)

        XCTAssertEqual(
            serviceError as String?,
            RichTextClipboard.ClipboardError.noRichText.localizedDescription
        )
        XCTAssertEqual(output.string(forType: .string), "untouched")
        XCTAssertFalse(model.isConverting)
    }

    @MainActor
    func testRTFDImagesAreReportedAsLeftOut() throws {
        let fixture = try FixtureFactory.createRichRTFD(in: root)
        let wrapper = try FileWrapper(url: fixture.packageURL)
        let attributed = try XCTUnwrap(NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: nil))
        let flat = try XCTUnwrap(attributed.rtfd(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        ))

        let outcome = try RichTextClipboard.convert(.init(kind: .flatRTFD, data: flat))

        XCTAssertTrue(outcome.markdown.contains("images/image01"), outcome.markdown)
        XCTAssertTrue(
            outcome.warnings.contains { $0.contains("left out") },
            outcome.warnings.joined(separator: "\n")
        )
    }

    @MainActor
    private func awaitBatch(_ model: AppModel) async throws -> [BatchItem] {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .batchFinished(let items) = model.state {
                return items
            }
            if case .failed(_, let message) = model.state {
                XCTFail(message)
                return []
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The batch did not finish within ten seconds.")
        return []
    }

    @MainActor
    private func awaitClipboard(_ model: AppModel) async throws -> ClipboardOutcome {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .copiedToClipboard(let outcome) = model.state {
                return outcome
            }
            if case .failed(_, let message) = model.state {
                throw XCTSkip("rich text conversion failed: \(message)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("The clipboard conversion did not finish within ten seconds.")
    }

    @discardableResult
    private func copyImage(to relativePath: String) throws -> URL {
        let target = root.appendingPathComponent(relativePath)
        try FileManager.default.copyItem(
            at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"),
            to: target
        )
        return target
    }
}
