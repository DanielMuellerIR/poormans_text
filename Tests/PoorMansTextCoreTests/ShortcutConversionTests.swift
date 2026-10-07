import AppIntents
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import PoorMansTextAppSupport
@testable import PoorMansTextCore

@MainActor
final class ShortcutConversionTests: XCTestCase {
    private var root: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutTests-\(UUID())")
        destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testURLInputConvertsCSVWithTSVOptionAndPreservesSource() async throws {
        let source = root.appendingPathComponent("source.csv")
        let bytes = Data("name,value\nAlpha,42\nBeta,17\n".utf8)
        try bytes.write(to: source)
        var intent = configured(document: IntentFile(fileURL: source))
        intent.spreadsheetFormat = .tsv
        let result = try await intent.perform()
        let output = try XCTUnwrap(result.value?.fileURL)
        XCTAssertEqual(output, destination.appendingPathComponent("source-markdown", isDirectory: true))
        let markdown = try String(contentsOf: output.appendingPathComponent("source.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Alpha\t42"), markdown)
        XCTAssertTrue(markdown.contains("Beta\t17"), markdown)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testMemoryInputCreatesACompleteTextbundle() async throws {
        var intent = configured(document: IntentFile(data: Data("name,value\nAlpha,42\n".utf8), filename: "memory.csv", type: .commaSeparatedText))
        intent.textbundle = true
        let result = try await intent.perform()
        let output = try XCTUnwrap(result.value?.fileURL)
        XCTAssertEqual(output.lastPathComponent, "memory.textbundle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("info.json").path))
        XCTAssertTrue(try String(contentsOf: output.appendingPathComponent("text.md"), encoding: .utf8).contains("Alpha"))
        XCTAssertFalse(try XCTUnwrap(result.value).removedOnCompletion)
    }

    func testTextbundleRetainsRTFDImagesAndSourceBytes() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/pandoc") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/pandoc") else {
            throw XCTSkip("Pandoc is not installed")
        }
        let fixture = try FixtureFactory.createRichRTFD(in: root)
        let sourceBefore = try Data(contentsOf: fixture.packageURL.appendingPathComponent("TXT.rtf"))
        var intent = configured(document: IntentFile(fileURL: fixture.packageURL))
        intent.textbundle = true
        let result = try await intent.perform()
        let output = try XCTUnwrap(result.value?.fileURL)
        let markdown = try String(contentsOf: output.appendingPathComponent("text.md"), encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "![").count - 1, 2)
        let assets = try FileManager.default.contentsOfDirectory(at: output.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(try assets.map { try Data(contentsOf: $0) }), Set(fixture.imageData))
        XCTAssertEqual(try Data(contentsOf: fixture.packageURL.appendingPathComponent("TXT.rtf")), sourceBefore)
    }

    func testExistingOutputIsNotOverwritten() async throws {
        let intent = configured(document: IntentFile(data: Data("name\nAlpha\n".utf8), filename: "memory.csv"))
        let first = try await intent.perform()
        let output = try XCTUnwrap(first.value?.fileURL)
        let marker = output.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        do { _ = try await intent.perform(); XCTFail("Expected an output collision") }
        catch { XCTAssertTrue(error.localizedDescription.contains("will not be overwritten"), error.localizedDescription) }
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }

    func testCancelledInvocationDoesNotPublishOutput() async throws {
        let intent = configured(document: IntentFile(data: Data("name\nAlpha\n".utf8), filename: "cancel.csv"))
        let task = Task { try await intent.perform() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cancelled"), error.localizedDescription) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testInvalidTimeoutAndDestinationAreReported() async throws {
        var intent = configured(document: IntentFile(data: Data("name\nAlpha\n".utf8), filename: "source.csv"))
        intent.toolTimeout = .nan
        do { _ = try await intent.perform(); XCTFail("Expected timeout validation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("positive"), error.localizedDescription) }
        intent.toolTimeout = 120
        let file = root.appendingPathComponent("file.txt")
        try Data().write(to: file)
        intent.destinationFolder = IntentFile(fileURL: file)
        do { _ = try await intent.perform(); XCTFail("Expected folder validation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("destination folder"), error.localizedDescription) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testUnsafeMemoryFilenameDoesNotEscapeStaging() async throws {
        let intent = configured(document: IntentFile(data: Data("name\nAlpha\n".utf8), filename: "../escape.csv"))
        do { _ = try await intent.perform(); XCTFail("Expected filename validation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("filename"), error.localizedDescription) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    private func configured(document: IntentFile) -> ConvertDocumentIntent {
        var intent = ConvertDocumentIntent()
        intent.document = document
        intent.destinationFolder = IntentFile(fileURL: destination, type: .folder)
        return intent
    }
}
