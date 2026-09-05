import AppKit
import Foundation
import XCTest
@testable import PoorMansTextAppSupport

/// Die App nimmt mehrere Dateien und Ordner auf einmal an — per Drop, Dialog
/// oder Öffnen-Ereignis — und zeigt je Eingabe ein Ergebnis. Bilder ohne OCR
/// brauchen weder Pandoc noch Vision, deshalb laufen diese Tests überall.
final class AppModelBatchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextAppBatchTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testSeveralFilesFinishAsAListWithOneEntryPerInput() async throws {
        let first = try copyImage(to: "Eins.png")
        let broken = root.appendingPathComponent("Kaputt.png")
        try Data("not a png".utf8).write(to: broken)
        let second = try copyImage(to: "Zwei.png")
        let model = AppModel(defaults: .isolatedForAppTest())
        model.imageTextRecognition = .disabled

        model.convert([first, broken, second])
        XCTAssertTrue(model.isConverting)
        XCTAssertFalse(model.acceptsNewDocuments)

        let items = try await awaitBatch(model)
        XCTAssertEqual(items.map { $0.input.lastPathComponent }, ["Eins.png", "Kaputt.png", "Zwei.png"])
        XCTAssertEqual(items.map { $0.result != nil }, [true, false, true])
        if case .failed(let message) = items[1].outcome {
            XCTAssertTrue(message.hasPrefix("Invalid IMAGE input"), message)
        } else {
            XCTFail("The broken image did not fail.")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Zwei-markdown/Zwei.md").path
            )
        )
        XCTAssertTrue(model.acceptsNewDocuments)
        model.selectResult(items[0])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        model.copyMarkdown(to: pasteboard)
        XCTAssertTrue(model.actionMessage?.contains("not copied") == true)
        let result = try XCTUnwrap(items[0].result)
        XCTAssertEqual(pasteboard.string(forType: .string), try String(contentsOf: result.markdownFile, encoding: .utf8))
    }

    @MainActor
    func testADroppedFolderIsSearchedLikeInTheCLI() async throws {
        try copyImage(to: "Ordner/Deckblatt.png")
        try copyImage(to: "Ordner/Anhang/Foto.jpg")
        try Data("plain".utf8).write(to: root.appendingPathComponent("Ordner/Notiz.txt"))
        let folder = root.appendingPathComponent("Ordner")
        let model = AppModel(defaults: .isolatedForAppTest())
        model.imageTextRecognition = .disabled

        // Ein einzelner Ordner nimmt ebenfalls den Mehrfachweg.
        model.convert(folder)

        let items = try await awaitBatch(model)
        XCTAssertEqual(items.map { $0.input.lastPathComponent }, ["Foto.jpg", "Deckblatt.png"])
        XCTAssertTrue(items.allSatisfy { $0.result != nil })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("Anhang/Foto-markdown/Foto.md").path
            )
        )
    }

    @MainActor
    func testAnEmptyFolderFailsVisiblyInsteadOfFinishingSilently() async throws {
        let empty = root.appendingPathComponent("Leer", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let model = AppModel(defaults: .isolatedForAppTest())

        model.convert([empty])

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .failed(let input, let message) = model.state {
                XCTAssertEqual(input, empty)
                XCTAssertTrue(message.contains("no supported documents"), message)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The empty folder did not fail within five seconds.")
    }

    @MainActor
    func testDroppingSeveralProvidersConvertsAllOfThem() async throws {
        let first = try copyImage(to: "A.png")
        let second = try copyImage(to: "B.png")
        let model = AppModel(defaults: .isolatedForAppTest())
        model.imageTextRecognition = .disabled

        XCTAssertTrue(
            model.acceptDrop([
                NSItemProvider(object: first as NSURL),
                NSItemProvider(object: second as NSURL),
            ])
        )

        let items = try await awaitBatch(model)
        XCTAssertEqual(items.map { $0.input.lastPathComponent }, ["A.png", "B.png"])
        XCTAssertTrue(items.allSatisfy { $0.result != nil })
    }

    @MainActor
    func testOneChosenFileStillUsesTheSingleResultView() async throws {
        let image = try copyImage(to: "Solo.png")
        let model = AppModel(defaults: .isolatedForAppTest())
        model.imageTextRecognition = .disabled

        model.chooseDocument(selectDocuments: { [image] })

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            switch model.state {
            case .succeeded(let result):
                XCTAssertEqual(result.inputURL, image)
                return
            case .batchFinished:
                return XCTFail("A single file must not use the list view.")
            case .failed(_, let message):
                return XCTFail(message)
            case .idle, .converting, .convertingBatch, .copiedToClipboard:
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTFail("The single conversion did not finish within five seconds.")
    }

    @MainActor
    private func awaitBatch(_ model: AppModel) async throws -> [BatchItem] {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            switch model.state {
            case .batchFinished(let items):
                return items
            case .failed(_, let message):
                throw XCTSkip("unexpected failure: \(message)")
            case .succeeded:
                XCTFail("A batch finished as a single result.")
                return []
            case .idle, .converting, .convertingBatch, .copiedToClipboard:
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTFail("The batch did not finish within ten seconds.")
        return []
    }

    @discardableResult
    private func copyImage(to relativePath: String) throws -> URL {
        let target = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"),
            to: target
        )
        return target
    }
}
