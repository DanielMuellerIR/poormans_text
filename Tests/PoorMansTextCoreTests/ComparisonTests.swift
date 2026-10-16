import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class ComparisonTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTComparison-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRealPDFPagesUseVerifiedBytesAndNavigateToTheirOwnText() async throws {
        let source = try makePDF()
        let original = try Data(contentsOf: source)
        let result = try convert(source)
        let snapshot = try ComparisonSourceSnapshot.read(result)
        XCTAssertEqual(snapshot.data, original)
        let renderer = ComparisonSourceRenderer(snapshot)
        let count = try await renderer.prepare()
        XCTAssertEqual(count, 2)
        let first = try await renderer.render(1), second = try await renderer.render(2)
        XCTAssertGreaterThan(try color(first).redComponent, 0.8)
        XCTAssertGreaterThan(try color(second).blueComponent, 0.8)
        let markdown = try Data(contentsOf: result.markdownFile)
        for (number, marker) in [(1, "PageOneMarker"), (2, "PageTwoMarker")] {
            let target = try XCTUnwrap(ComparisonNavigation.target(for: ConversionLocation(page: number), mappings: result.sourceMappings))
            XCTAssertTrue(target.exact)
            XCTAssertTrue(target.range.text(in: markdown)?.contains(marker) == true)
            XCTAssertEqual(String(decoding: markdown, as: UTF8.self).components(separatedBy: marker).count - 1, 1)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testRendererKeepsTheVerifiedSnapshotAfterThePathChanges() async throws {
        let source = try makePDF()
        let result = try convert(source)
        let snapshot = try ComparisonSourceSnapshot.read(result)
        try Data("replacement".utf8).write(to: source, options: .atomic)
        let renderer = ComparisonSourceRenderer(snapshot)
        let count = try await renderer.prepare()
        XCTAssertEqual(count, 2)
        let page = try await renderer.render(2)
        XCTAssertGreaterThan(try color(page).blueComponent, 0.8)
        XCTAssertThrowsError(try ComparisonSourceSnapshot.read(result)) { XCTAssertEqual($0 as? ComparisonSourceSnapshot.Failure, .changed) }
    }

    func testActualTIFFFramesAreDistinctAndDoNotChangeTheOriginalAsset() async throws {
        let source = try makeTIFF()
        let original = try Data(contentsOf: source)
        let result = try convert(source)
        let renderer = ComparisonSourceRenderer(try ComparisonSourceSnapshot.read(result))
        let count = try await renderer.prepare()
        XCTAssertEqual(count, 2)
        let first = try await renderer.render(1), second = try await renderer.render(2)
        XCTAssertGreaterThan(try color(first).redComponent, 0.8)
        XCTAssertGreaterThan(try color(second).blueComponent, 0.8)
        do { _ = try await renderer.render(3); XCTFail("An absent frame must not be displayed") } catch {}
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), original)
    }

    func testChangedMissingAndSymlinkedSourcesCannotBeVerified() throws {
        let source = root.appendingPathComponent("values.csv")
        let original = Data("Name,Value\nMarker,42\n".utf8)
        try original.write(to: source)
        let result = try convert(source)
        XCTAssertNil(try ComparisonSourceSnapshot.read(result).data)
        try Data("Name,Value\nMarker,43\n".utf8).write(to: source)
        XCTAssertThrowsError(try ComparisonSourceSnapshot.read(result)) { XCTAssertEqual($0 as? ComparisonSourceSnapshot.Failure, .changed) }
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try ComparisonSourceSnapshot.read(result)) { XCTAssertEqual($0 as? ComparisonSourceSnapshot.Failure, .missing) }
        let elsewhere = root.appendingPathComponent("elsewhere.csv")
        try original.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ComparisonSourceSnapshot.read(result)) { XCTAssertEqual($0 as? ComparisonSourceSnapshot.Failure, .unreadable) }
    }

    func testCellNavigationDoesNotInventASheetOrAnExactPosition() throws {
        let mappings = [
            ConversionSourceMapping(source: ConversionLocation(sheet: "First", cell: "A1"), output: ConversionTextRange(file: "text.md", utf8Offset: 0, utf8Length: 5)),
            ConversionSourceMapping(source: ConversionLocation(sheet: "Second", cell: "A1"), output: ConversionTextRange(file: "text.md", utf8Offset: 10, utf8Length: 5)),
            ConversionSourceMapping(source: ConversionLocation(sheet: "Second", cell: "B2"), output: ConversionTextRange(file: "text.md", utf8Offset: 20, utf8Length: 5)),
        ]
        XCTAssertNil(ComparisonNavigation.target(for: ConversionLocation(cell: "A1"), mappings: mappings))
        let exact = try XCTUnwrap(ComparisonNavigation.target(for: ConversionLocation(sheet: "Second", cell: "B2"), mappings: mappings))
        XCTAssertTrue(exact.exact); XCTAssertEqual(exact.range.utf8Offset, 20)
        let coarse = try XCTUnwrap(ComparisonNavigation.target(for: ConversionLocation(sheet: "Second", cell: "Z99"), mappings: mappings))
        XCTAssertFalse(coarse.exact); XCTAssertEqual(coarse.range.utf8Offset, 10)
        XCTAssertNil(ComparisonNavigation.target(for: ConversionLocation(sheet: "Missing"), mappings: mappings))
        XCTAssertEqual(ComparisonNavigation.sections(mappings).map { $0.location.sheet }, ["First", "Second"])
        XCTAssertEqual(ComparisonNavigation.sections(mappings, limit: 1).count, 1)
    }

    func testDiagnosticsFilterMeaningAndUnknownLocationsWithoutDroppingDetails() {
        let information = ConversionWarning(code: "info", message: "Information marker", kind: .information)
        let loss = ConversionWarning(code: "loss", message: "Loss marker", location: ConversionLocation(sheet: "Budget🙂", cell: "B4"), kind: .contentLoss)
        XCTAssertTrue(ComparisonNavigation.matches(information, kind: .information, locationQuery: ""))
        XCTAssertFalse(ComparisonNavigation.matches(loss, kind: .information, locationQuery: ""))
        XCTAssertTrue(ComparisonNavigation.matches(loss, kind: .contentLoss, locationQuery: "budget🙂"))
        XCTAssertTrue(ComparisonNavigation.matches(loss, kind: nil, locationQuery: "B4"))
        XCTAssertFalse(ComparisonNavigation.matches(information, kind: nil, locationQuery: "B4"))
        XCTAssertFalse(ComparisonNavigation.label(nil).isEmpty)
        XCTAssertNil(ComparisonNavigation.target(for: nil, mappings: []))
    }

    func testLegacySlidePageAliasAndNotesUseTheKnownSlideSection() throws {
        let mapping = ConversionSourceMapping(source: ConversionLocation(slide: 2), output: ConversionTextRange(file: "text.md", utf8Offset: 40, utf8Length: 25))
        for location in [ConversionLocation(page: 2, slide: 2, paragraph: 2), ConversionLocation(page: 2, slide: 2, note: "notesSlide1.xml")] {
            let target = try XCTUnwrap(ComparisonNavigation.target(for: location, mappings: [mapping]))
            XCTAssertFalse(target.exact); XCTAssertEqual(target.range.utf8Offset, 40)
        }
        XCTAssertTrue(try XCTUnwrap(ComparisonNavigation.target(for: ConversionLocation(page: 2, slide: 2), mappings: [mapping])).exact)
        XCTAssertNil(ComparisonNavigation.target(for: ConversionLocation(page: 3, slide: 2), mappings: [mapping]))
    }

    func testLargeVerifiedSourceIsNotRetainedForRendering() async throws {
        let source = root.appendingPathComponent("large.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(ComparisonSourceSnapshot.maximumPreviewBytes + 1)); try file.close()
        let fingerprint = try ConversionFileFingerprint.read(source)
        let result = ConversionResult(inputURL: source, format: .pdf, outputDirectory: root, markdownFile: root.appendingPathComponent("text.md"),
            assets: [], outputLifetime: .temporary, diagnostics: [],
            sourceIdentity: ConversionSourceIdentity(name: source.lastPathComponent, sha256: fingerprint.sha256, byteCount: fingerprint.byteCount, unavailableReason: nil))
        let snapshot = try ComparisonSourceSnapshot.read(result)
        XCTAssertNil(snapshot.data)
        do { _ = try await ComparisonSourceRenderer(snapshot).prepare(); XCTFail("Large source must not be decoded") }
        catch { XCTAssertEqual(error as? ComparisonSourceSnapshot.Failure, .limit) }
    }

    @MainActor func testMissingFingerprintRemainsExplicitlyUnverified() async throws {
        let source = root.appendingPathComponent("plain.csv")
        try Data("Name,Value\nMarker,42\n".utf8).write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let model = ComparisonSourceModel()
        defer { model.stop() }
        model.load(result)
        try await waitUntil { model.state == .unverified }
        XCTAssertFalse(model.isVerified); XCTAssertNil(model.image)
    }

    @MainActor func testLiveSourceChangesInvalidateTheComparisonAndCanBeRechecked() async throws {
        let source = root.appendingPathComponent("values.csv")
        let original = Data("Name,Value\nMarker,42\n".utf8)
        try original.write(to: source)
        let result = try convert(source)
        let model = ComparisonSourceModel()
        defer { model.stop() }
        model.load(result)
        try await waitUntil { model.state == .verified }
        try Data("Name,Value\nMarker,43\n".utf8).write(to: source, options: .atomic)
        try await waitUntil { model.state == .changed }
        XCTAssertNil(model.image)
        model.load(result)
        try await waitUntil { model.state == .changed }
        try original.write(to: source, options: .atomic)
        model.load(result)
        try await waitUntil { model.state == .verified }
        try FileManager.default.removeItem(at: source)
        model.load(result)
        try await waitUntil { model.state == .missing }
    }

    @MainActor func testRapidFrameAndDocumentChangesDiscardOldImages() async throws {
        let result = try convert(makeTIFF())
        let model = ComparisonSourceModel()
        defer { model.stop() }
        model.load(result)
        try await waitUntil { model.count == 2 && model.image != nil }
        model.select(2); model.select(1)
        try await waitUntil { !model.imageBusy }
        XCTAssertEqual(model.number, 1)
        let bitmap = try XCTUnwrap(model.image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB)).redComponent, 0.8)
        let source = root.appendingPathComponent("other.csv")
        try Data("Other,Value\nAnother,12\n".utf8).write(to: source)
        model.load(try convert(source))
        try await waitUntil { model.state == .verified }
        XCTAssertEqual(model.count, 0); XCTAssertNil(model.image)
        model.stop()
    }

    private func convert(_ source: URL) throws -> ConversionResult {
        try DocumentConverter().convert(ConversionRequest(inputURL: source,
            destination: .directory(root.appendingPathComponent(UUID().uuidString)),
            options: ConversionOptions(imageTextRecognition: .disabled, pdfTextRecognition: .disabled, sourceMapping: true)))
    }
    private func makePDF() throws -> URL {
        let source = root.appendingPathComponent(UUID().uuidString + ".pdf")
        var bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        let consumer = try XCTUnwrap(CGDataConsumer(url: source as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for (text, color) in [("PageOneMarker with enough readable digital text.", NSColor.red), ("PageTwoMarker with enough readable digital text.", NSColor.blue)] {
            context.beginPDFPage(nil)
            context.setFillColor(color.cgColor); context.fill(bounds)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 10)!, .foregroundColor: NSColor.white]).draw(at: CGPoint(x: 10, y: 120))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF(); return source
    }
    private func makeTIFF() throws -> URL {
        let source = root.appendingPathComponent(UUID().uuidString + ".tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        for color in [NSColor.red, .blue] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return source
    }
    private func color(_ data: Data) throws -> NSColor {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        return try XCTUnwrap(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}
