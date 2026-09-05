import AppKit
import Darwin
import XCTest
import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class AppOptionsTests: XCTestCase {
    @MainActor
    func testPreferencesReachRequestAndSurviveReload() throws {
        let name = "AppOptionsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: defaults)
        model.destinationFolder = URL(fileURLWithPath: "/tmp/output")
        model.frontmatter = true
        model.imageTextRecognition = .disabled
        model.spreadsheetRendering = .tabSeparated
        model.outputLayout = .textbundle
        model.batchParallelism = 3
        model.pdfTextRecognition = .always
        model.pdfLayout = .legacy
        model.ocrLanguageCodes = "de,en"
        model.pdfRemoveHeadersFooters = true
        model.pdfDehyphenate = true
        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.conversionOptions, model.conversionOptions)
        XCTAssertEqual(restored.batchParallelism, 3)
        let request = restored.request(for: URL(fileURLWithPath: "/tmp/input.csv"), options: restored.conversionOptions)
        XCTAssertEqual(request.destination, .directory(URL(fileURLWithPath: "/tmp/output/input.textbundle")))
        XCTAssertTrue(request.options.frontmatter)
        XCTAssertEqual(request.options.ocrLanguages, ["de", "en"])
        XCTAssertEqual(request.options.pdfTextRecognition, .always)
        XCTAssertTrue(request.options.pdfRemoveHeadersFooters)
        XCTAssertTrue(request.options.pdfDehyphenate)
    }

    @MainActor
    func testCSVBatchCollisionRetryPreservesSuccessAndSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.csv")
        let second = root.appendingPathComponent("second.csv")
        let source = Data("Name,Value\nAlpha,42\nBeta,57\n".utf8)
        try source.write(to: first)
        try source.write(to: second)
        let collision = root.appendingPathComponent("second.textbundle")
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        let sentinel = collision.appendingPathComponent("keep.txt")
        try Data("old output".utf8).write(to: sentinel)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.frontmatter = true
        model.outputLayout = .textbundle
        model.spreadsheetRendering = .tabSeparated
        model.convert([first, second])
        try await wait(model)
        guard case .batchFinished(let items) = model.state else { return XCTFail("No batch") }
        XCTAssertEqual(items.map { $0.result != nil }, [true, false])
        let result = try XCTUnwrap(items[0].result)
        let original = try Data(contentsOf: result.markdownFile)
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("```tsv"), text)
        for value in ["Alpha", "42", "Beta", "57"] { XCTAssertEqual(text.components(separatedBy: value).count - 1, 1) }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "old output")
        // Das zweite Ziel wechselt ausdrücklich; die alte Ausgabe bleibt stehen.
        let newRoot = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        model.destinationFolder = newRoot
        model.retryFailed()
        try await wait(model)
        guard case .batchFinished(let retried) = model.state else { return XCTFail("No retried batch") }
        XCTAssertEqual(retried.map(\.input), [first, second])
        XCTAssertTrue(retried.allSatisfy { $0.result != nil })
        XCTAssertEqual(retried[0].result?.markdownFile, result.markdownFile)
        XCTAssertEqual(try Data(contentsOf: result.markdownFile), original)
        XCTAssertEqual(try Data(contentsOf: first), source)
        XCTAssertEqual(try Data(contentsOf: second), source)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "old output")
        model.selectResult(retried[1])
        XCTAssertEqual(model.selectedResult?.markdownFile, retried[1].result?.markdownFile)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        model.copyMarkdown(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), try String(contentsOf: XCTUnwrap(retried[1].result).markdownFile, encoding: .utf8))
    }

    @MainActor
    func testFolderDestinationPreservesSubdirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        for directory in ["a", "b"] {
            let folder = input.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Name,Value\n\(directory),123\n".utf8).write(to: folder.appendingPathComponent("same.csv"))
        }
        let model = AppModel(defaults: .isolatedForAppTest())
        model.destinationFolder = root.appendingPathComponent("output")
        model.convert(input)
        try await wait(model)
        guard case .batchFinished(let items) = model.state else { return XCTFail("No batch") }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.result != nil })
        XCTAssertEqual(Set(items.compactMap { $0.result?.outputDirectory.deletingLastPathComponent().lastPathComponent }), Set(["a", "b"]))
        // Ein neuer Einzelauftrag ohne reset darf die alte Batch-Unterstruktur
        // nicht wiederverwenden; nur Retry gehört noch zum alten Auftrag.
        model.convert(input.appendingPathComponent("a/same.csv"))
        try await wait(model)
        guard case .succeeded(let single) = model.state else { return XCTFail("New single conversion failed") }
        XCTAssertEqual(single.outputDirectory.deletingLastPathComponent().lastPathComponent, "output")
    }

    @MainActor
    func testAdjacentBatchOutputNeverWritesInsideAnotherSourcePackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("source.rtfd")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let file = package.appendingPathComponent("TXT.rtf")
        let bytes = Data(#"{\rtf1\ansi Unchanged}"#.utf8)
        try bytes.write(to: file)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.batchParallelism = 2
        model.convert([file, package])
        try await wait(model)
        guard case .batchFinished(let items) = model.state else { return XCTFail("No batch result") }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.result == nil })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.path), ["TXT.rtf"])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.rtfd"])
    }

    @MainActor
    func testBatchDoesNotCreateParentsInsideAnySourcePackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("source.rtfd")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let rtf = Data(#"{\rtf1\ansi Source remains unchanged}"#.utf8)
        try rtf.write(to: package.appendingPathComponent("TXT.rtf"))
        let csv = root.appendingPathComponent("table.csv")
        try Data("Name,Value\nAlpha,42\n".utf8).write(to: csv)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.batchParallelism = 2
        model.destinationFolder = package.appendingPathComponent("new/nested")
        model.convert([csv, package])
        try await wait(model)
        guard case .batchFinished(let items) = model.state else { return XCTFail("No batch") }
        XCTAssertTrue(items.allSatisfy { $0.result == nil })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.path), ["TXT.rtf"])
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("TXT.rtf")), rtf)
    }

    @MainActor
    func testRetryAfterEnumerationFailureKeepsAllInputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.csv")
        let last = root.appendingPathComponent("last.csv")
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in [first, last] { try Data("Name,Value\nAlpha,42\n".utf8).write(to: url) }
        let model = AppModel(defaults: .isolatedForAppTest())
        model.convert([first, folder, last])
        try await wait(model)
        guard case .failed = model.state else { return XCTFail("Expected enumeration failure") }
        let middle = folder.appendingPathComponent("middle.csv")
        try Data("Name,Value\nMiddle,77\n".utf8).write(to: middle)
        model.retryFailed()
        try await wait(model)
        guard case .batchFinished(let items) = model.state else { return XCTFail("No batch") }
        XCTAssertEqual(items.map(\.input), [first, middle, last])
        XCTAssertTrue(items.allSatisfy { $0.result != nil })
    }

    func testGermanCollisionMessagePreservesPath() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: repo.appendingPathComponent("App/de.lproj")))
        let message = AppErrorMessage.describe(ConversionError.outputAlreadyExists(URL(fileURLWithPath: "/tmp/keep")), bundle: bundle)
        XCTAssertEqual(message, "Die Ausgabe existiert bereits und wird nicht überschrieben: /tmp/keep")
    }

    func testBoundedPreviewAndFIFORejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.md")
        try Data("abc😀tail".utf8).write(to: file)
        let preview = try MarkdownPreview.read(file, limit: 5)
        XCTAssertEqual(preview.text, "abc")
        XCTAssertTrue(preview.truncated)
        XCTAssertEqual(try MarkdownPreview.read(file).text, "abc😀tail")
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                _ = try MarkdownPreview.read(fifo)
                XCTFail("FIFO was accepted")
            } catch { /* Reguläre Dateien sind die einzige zulässige Quelle. */ }
            finished.signal()
        }
        let status = finished.wait(timeout: .now() + 1)
        if status == .timedOut {
            // Ein regressiver blockierender Leser wird vor dem Testende
            // entsperrt; die Suite wartet trotzdem höchstens eine Sekunde.
            let writer = open(fifo.path, O_RDWR | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        XCTAssertEqual(status, .success)
    }

    @MainActor private func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.isConverting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isConverting)
    }
}

extension UserDefaults {
    /// Flüchtiger Store ohne Dateischreibzugriff und ohne globale App-Einstellungen.
    static func isolatedForAppTest() -> UserDefaults { VolatileAppTestDefaults() }
}

private final class VolatileAppTestDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "VolatileAppTestDefaults-\(UUID())")! }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
}
