import AppKit
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
        let output = try resultFolder(result.value)
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
        let output = try resultFolder(result.value)
        XCTAssertEqual(output.lastPathComponent, "memory.textbundle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("info.json").path))
        XCTAssertTrue(try String(contentsOf: output.appendingPathComponent("text.md"), encoding: .utf8).contains("Alpha"))
        XCTAssertTrue(try resultFolder(result.value).isFileURL)
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
        let output = try resultFolder(result.value)
        let markdown = try String(contentsOf: output.appendingPathComponent("text.md"), encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "![").count - 1, 2)
        let assets = try FileManager.default.contentsOfDirectory(at: output.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(try assets.map { try Data(contentsOf: $0) }), Set(fixture.imageData))
        XCTAssertEqual(try Data(contentsOf: fixture.packageURL.appendingPathComponent("TXT.rtf")), sourceBefore)
    }

    func testExistingOutputIsNotOverwritten() async throws {
        let intent = configured(document: IntentFile(data: Data("name\nAlpha\n".utf8), filename: "memory.csv"))
        let first = try await intent.perform()
        let output = try resultFolder(first.value)
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

    func testWarningsFollowTheResultFolderWithoutRequiringADialog() async throws {
        let source = root.appendingPathComponent("warning.html")
        let data = Data("<p>Retained text</p><img src='missing.png' alt='Missing image'>".utf8)
        try data.write(to: source)
        let result = try await configured(document: IntentFile(fileURL: source)).perform()
        let values = try XCTUnwrap(result.value)
        let output = try resultFolder(values)
        XCTAssertGreaterThan(values.count, 1)
        XCTAssertTrue(try String(contentsOf: output.appendingPathComponent("warning.md"), encoding: .utf8).contains("Retained text"))
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testStructuredOCRParameterReachesRealImageConversion() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires structured Vision") }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 400).fill()
        ("Native structured import" as NSString).draw(at: NSPoint(x: 70, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = root.appendingPathComponent("structured.png")
        try bytes.write(to: source)
        let intent = configured(document: IntentFile(fileURL: source))
        XCTAssertNil(intent.ocrMethod)
        XCTAssertEqual(try intent.explicitOptions().ocrMethod, .standard)
        intent.ocrMethod = .structured
        let result = try await intent.perform()
        let output = try resultFolder(result.value)
        let markdown = try String(contentsOf: output.appendingPathComponent("structured.md"), encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "Native structured import").count - 1, 1, markdown)
        XCTAssertTrue(try XCTUnwrap(result.value).contains { $0.contains("Structured local OCR was used.") })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("images/image01.png")), bytes)
    }

    private func resultFolder(_ values: [String]?) throws -> URL {
        let first = try XCTUnwrap(try XCTUnwrap(values).first)
        let url = try XCTUnwrap(URL(string: first))
        XCTAssertTrue(url.isFileURL)
        return url
    }

    func testDOCXReviewModesReachIntentConversionWithCommentsAndNotes() async throws {
        let source = try DOCXReviewFixture.make(in: root)
        for mode in [ShortcutDOCXChangeMode.reject, .mark] {
            let folder = destination.appendingPathComponent(mode.rawValue)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            var intent = configured(document: IntentFile(fileURL: source))
            intent.destinationFolder = IntentFile(fileURL: folder, type: .folder)
            intent.docxChangeMode = mode
            let result = try await intent.perform()
            let output = try resultFolder(result.value)
            let markdown = try String(contentsOf: output.appendingPathComponent("review.md"), encoding: .utf8)
            let body = markdown.components(separatedBy: "## Document comments")[0]
            XCTAssertTrue(body.contains("DELETEONLY"))
            XCTAssertEqual(body.contains("INSERTONLY"), mode == .mark)
            XCTAssertTrue(body.contains("END_OLD"))
            XCTAssertTrue(markdown.contains("### Comment 6"))
        }
    }

    private func configured(document: IntentFile) -> ConvertDocumentIntent {
        var intent = ConvertDocumentIntent()
        intent.document = document
        intent.destinationFolder = IntentFile(fileURL: destination, type: .folder)
        return intent
    }

    func testPDFAnnotationsReachIntentWithSelectedPagesAndTextbundle() async throws {
        let source = try PDFAnnotationFixture.make(in: root), before = try Data(contentsOf: source)
        var intent = configured(document: IntentFile(fileURL: source))
        intent.pdfPages = "1"; intent.textbundle = true; intent.pdfOCR = .disabled
        let result = try await intent.perform()
        let output = try resultFolder(result.value)
        let markdown = try String(contentsOf: output.appendingPathComponent("text.md"),encoding: .utf8)
        XCTAssertTrue(markdown.contains("COMMENT\\_BODY")); XCTAssertTrue(markdown.contains(MarkdownEscaping.linkDestination(PDFAnnotationFixture.encodedWeb)))
        XCTAssertFalse(markdown.contains("#pmt-pdf-page-2")); XCTAssertFalse(markdown.contains("BODY_TWO"))
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
}
