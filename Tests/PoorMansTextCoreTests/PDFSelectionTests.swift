import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import PoorMansTextCore

final class PDFSelectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTPDFSelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRangeSyntaxNormalizesOrderDuplicatesAndOverlapsAndRoundTrips() throws {
        let selection = try IndexSelection("5, 2-3, 1, 3-4, 8, 8")
        XCTAssertEqual(selection.description, "1-5,8")
        XCTAssertEqual(try selection.zeroBasedIndices(itemCount: 8), [0, 1, 2, 3, 4, 7])
        XCTAssertEqual(try JSONDecoder().decode(IndexSelection.self, from: JSONEncoder().encode(selection)), selection)
        let edge = try IndexSelection(ranges: [(Int.max - 1)...(Int.max - 1), Int.max...Int.max])
        XCTAssertEqual(try edge.zeroBasedIndices(itemCount: Int.max), [Int.max - 2, Int.max - 1])
    }

    func testInvalidEmptyHugeAndOutOfBoundsSelectionsAreRejected() throws {
        for expression in ["", " ", "0", "-1", "3-2", "1-", "1,,2", "+1", "1–3", "1-2-3", "1.5", "x", String(Int.max) + "0"] {
            XCTAssertThrowsError(try IndexSelection(expression), expression)
        }
        XCTAssertThrowsError(try IndexSelection(ranges: []))
        XCTAssertThrowsError(try IndexSelection(ranges: [(-1)...2]))
        XCTAssertThrowsError(try IndexSelection(String(repeating: "1,", count: 1024) + "1"))
        XCTAssertThrowsError(try IndexSelection(String(repeating: "1", count: 65_537)))
        XCTAssertThrowsError(try IndexSelection("1-\(Int.max)").zeroBasedIndices(itemCount: Int.max))
        XCTAssertThrowsError(try IndexSelection("4").zeroBasedIndices(itemCount: 3))
        XCTAssertThrowsError(try IndexSelection("1").zeroBasedIndices(itemCount: 0))
    }

    func testSelectedPagesKeepSourceNumbersTextMappingsAndReportsInBothLayouts() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: ["PageOneMarker", "PageTwoMarker", "PageThreeMarker", "PageFourMarker", ""])
        let original = try Data(contentsOf: source)
        for layout in [PDFLayout.automatic, .legacy] {
            for output in [OutputLayout.markdownFolder, .textbundle] {
                let result = try convert(source, options: ConversionOptions(frontmatter: true, outputLayout: output, pdfTextRecognition: .disabled,
                    pdfLayout: layout, pdfPages: IndexSelection("5,2,4,2"), conversionReport: true))
                let bytes = try Data(contentsOf: result.markdownFile), text = String(decoding: bytes, as: UTF8.self)
                for marker in ["PageTwoMarker", "PageFourMarker"] { XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1) }
                XCTAssertFalse(text.contains("PageOneMarker")); XCTAssertFalse(text.contains("PageThreeMarker"))
                let headings = text.components(separatedBy: "\n").filter { $0.hasPrefix("## Page ") }
                XCTAssertEqual(headings, ["## Page 2", "## Page 4", "## Page 5"])
                XCTAssertEqual(result.sourceMappings.compactMap { $0.source.page }, [2, 4, 5])
                XCTAssertTrue(result.sourceMappings[0].output.text(in: bytes)?.contains("PageTwoMarker") == true)
                XCTAssertTrue(result.sourceMappings[1].output.text(in: bytes)?.contains("PageFourMarker") == true)
                XCTAssertTrue(result.sourceMappings[2].output.text(in: bytes)?.contains("No text could be extracted") == true)
                XCTAssertEqual(result.diagnostics.filter { $0.code == "pdf.pageTextUnavailable" }.compactMap { $0.location?.page }, [5])
                let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
                XCTAssertEqual(report.options.pdfPages?.description, "2,4-5")
                XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
                XCTAssertEqual(try Data(contentsOf: source), original)
            }
        }
    }

    func testNoSelectionAndExplicitAllPagesHaveIdenticalMarkdown() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: ["FirstMarker", "SecondMarker", "ThirdMarker"])
        for layout in [PDFLayout.automatic, .legacy] {
            let all = try convert(source, options: ConversionOptions(pdfTextRecognition: .disabled, pdfLayout: layout, conversionReport: true))
            let explicit = try convert(source, options: ConversionOptions(pdfTextRecognition: .disabled, pdfLayout: layout, pdfPages: IndexSelection("1-3")))
            XCTAssertEqual(try Data(contentsOf: all.markdownFile), try Data(contentsOf: explicit.markdownFile))
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(all.reportFile))) as? [String: Any]
            XCTAssertNil((json?["options"] as? [String: Any])?["pdfPages"])
        }
    }

    func testOCRAutoAlwaysAndOffOnlyProcessTheSelectedScanAndKeepItsNumber() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: ["FirstMarker digital page", "SCAN TWO MARKER", "ThirdMarker digital page"], scanPages: [2])
        let original = try Data(contentsOf: source)
        for layout in [PDFLayout.automatic, .legacy] {
            for mode in [PDFTextRecognition.automatic, .always, .disabled] {
                let result = try convert(source, options: ConversionOptions(pdfTextRecognition: mode, pdfLayout: layout, pdfPages: IndexSelection("2"), sourceMapping: true))
                let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
                XCTAssertTrue(text.contains("## Page 2")); XCTAssertFalse(text.contains("FirstMarker")); XCTAssertFalse(text.contains("ThirdMarker"))
                XCTAssertEqual(result.sourceMappings.compactMap { $0.source.page }, [2])
                if mode == .disabled { XCTAssertFalse(text.contains("SCAN TWO MARKER")); XCTAssertFalse(result.diagnostics.contains { $0.code == "pdf.ocrApplied" }) }
                else { XCTAssertTrue(text.contains("SCAN TWO MARKER"), text); XCTAssertTrue(result.diagnostics.contains { $0.code == "pdf.ocrApplied" }) }
                XCTAssertEqual(try Data(contentsOf: source), original)
            }
        }
    }

    func testOCRBudgetCountsOnlySelectedWork() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: Array(repeating: "", count: 17), size: CGSize(width: 1000, height: 1000))
        let original = try Data(contentsOf: source)
        XCTAssertThrowsError(try convert(source, options: ConversionOptions(pdfTextRecognition: .always))) { XCTAssertTrue($0.localizedDescription.contains("pixel budget")) }
        let selected = try convert(source, options: ConversionOptions(pdfTextRecognition: .always, pdfPages: IndexSelection("17")))
        XCTAssertTrue(try String(contentsOf: selected.markdownFile, encoding: .utf8).contains("## Page 17"))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCleanupUsesSelectedPagesAndKeepsOriginalDiagnosticNumbers() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: ["OneMarker", "TwoMarker", "ThreeMarker", "FourMarker"], margins: true)
        let result = try convert(source, options: ConversionOptions(pdfTextRecognition: .disabled, pdfRemoveHeadersFooters: true,
            pdfDehyphenate: true, pdfPages: IndexSelection("4,2")))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertFalse(text.contains("REPEATED HEADER")); XCTAssertFalse(text.contains("REPEATED FOOTER"))
        XCTAssertTrue(text.contains("conversion"), text)
        XCTAssertFalse(text.contains("OneMarker")); XCTAssertFalse(text.contains("ThreeMarker"))
        XCTAssertEqual(result.diagnostics.filter { $0.code == "pdf.repeatedMarginRemoved" }.compactMap { $0.location?.page }, [2, 4])
    }

    func testDehyphenationDoesNotJoinAcrossOmittedPages() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: ["OneMarker", "TwoMarker", "ThreeMarker", "FourMarker"],
            extraLines: [2: [("cross-", CGPoint(x: 40, y: 90))], 4: [("page", CGPoint(x: 40, y: 690))]])
        let result = try convert(source, options: ConversionOptions(pdfTextRecognition: .disabled, pdfDehyphenate: true, pdfPages: IndexSelection("2,4")))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("cross-")); XCTAssertTrue(text.contains("page"))
        XCTAssertFalse(text.contains("crosspage")); XCTAssertFalse(text.contains("ThreeMarker"))
    }

    func testPageSelectionDoesNotBypassTheSourcePageLimit() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: Array(repeating: "", count: 1001))
        XCTAssertThrowsError(try convert(source, options: ConversionOptions(pdfPages: IndexSelection("1")))) {
            XCTAssertTrue($0.localizedDescription.contains("page limit"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try DocumentConverter().inspectPDFContents(source))
    }

    func testProgressUsesSelectedCountAndCancellationPublishesNothing() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: ["OneMarker", "TwoMarker", "ThreeMarker", "FourMarker"])
        let events = SelectionProgressEvents()
        _ = try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(root.appendingPathComponent("progress")),
            options: ConversionOptions(pdfTextRecognition: .disabled, pdfPages: IndexSelection("2,4"))), progress: { events.append($0) })
        let pages = events.values.filter { $0.unit == .page }
        XCTAssertFalse(pages.isEmpty); XCTAssertTrue(pages.allSatisfy { $0.total == 2 && (0...2).contains($0.completed ?? -1) })
        XCTAssertEqual(pages.last?.completed, 2)
        let token = ConversionCancellationToken(), destination = root.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(destination),
            options: ConversionOptions(pdfTextRecognition: .disabled, pdfPages: IndexSelection("2,4"))), progress: {
                if $0.unit == .page && $0.completed == 1 { token.cancel() }
            }, cancellation: token)) { error in
                guard case .cancelled? = error as? ConversionError else { return XCTFail(error.localizedDescription) }
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testInvalidSelectionAndWrongFormatDoNotPublish() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: ["OneMarker", "TwoMarker"])
        let destination = root.appendingPathComponent("invalid")
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(destination),
            options: ConversionOptions(pdfPages: IndexSelection("3")))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let csv = root.appendingPathComponent("values.csv");try Data("Name,Value\nMarker,42\n".utf8).write(to: csv)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: csv, destination: .directory(destination),
            options: ConversionOptions(pdfPages: IndexSelection("1")))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
    }

    func testBoundedOverviewReadsMetadataWithoutImportingOrRunningOCR() throws {
        let source = try PDFSelectionFixture.create(in: root, texts: ["OneMarker", "", "ThreeMarker"])
        let original = try Data(contentsOf: source)
        let summary = try DocumentConverter().inspectPDFContents(source, maximumPages: 2)
        XCTAssertEqual(summary.pageCount, 3); XCTAssertEqual(summary.pages.map(\.number), [1, 2]); XCTAssertTrue(summary.pagesTruncated)
        XCTAssertEqual(summary.pages[0].width, 612); XCTAssertEqual(summary.pages[0].height, 792)
        XCTAssertEqual(summary.sourceIdentity.sha256, ConversionFileFingerprint.digest(original))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
        XCTAssertThrowsError(try DocumentConverter().inspectPDFContents(source, maximumPages: 0))
        XCTAssertThrowsError(try DocumentConverter().inspectPDFContents(source, maximumPages: 501))
        let token = ConversionCancellationToken();token.cancel()
        XCTAssertThrowsError(try DocumentConverter().inspectPDFContents(source, cancellation: token)) { error in
            guard case .cancelled? = error as? ConversionError else { return XCTFail(error.localizedDescription) }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func convert(_ source: URL, options: ConversionOptions) throws -> ConversionResult {
        let suffix = options.outputLayout == .textbundle ? ".textbundle" : ""
        return try DocumentConverter().convert(ConversionRequest(inputURL: source,
            destination: .directory(root.appendingPathComponent(UUID().uuidString + suffix)), options: options))
    }
}

enum PDFSelectionFixture {
    static func create(in root: URL, texts: [String], scanPages: Set<Int> = [], margins: Bool = false,
                       size: CGSize = CGSize(width: 612, height: 792), extraLines: [Int: [(String, CGPoint)]] = [:]) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".pdf")
        var bounds = CGRect(origin: .zero, size: size)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for (index, text) in texts.enumerated() {
            context.beginPDFPage(nil)
            if scanPages.contains(index + 1) {
                let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1));bitmap.fill(CGRect(x: 0, y: 0, width: 1200, height: 500))
                line(text, at: CGPoint(x: 60, y: 230), size: 70, in: bitmap)
                context.draw(try XCTUnwrap(bitmap.makeImage()), in: CGRect(x: 30, y: 250, width: 550, height: 230))
            } else if !text.isEmpty { line(text + " has enough readable source text.", at: CGPoint(x: 40, y: 600), size: 14, in: context) }
            if margins {
                line("REPEATED HEADER", at: CGPoint(x: 40, y: 760), size: 12, in: context)
                line("REPEATED FOOTER", at: CGPoint(x: 40, y: 20), size: 12, in: context)
                line("conver-", at: CGPoint(x: 40, y: 400), size: 14, in: context)
                line("sion", at: CGPoint(x: 40, y: 380), size: 14, in: context)
            }
            for (text, point) in extraLines[index + 1] ?? [] { line(text, at: point, size: 14, in: context) }
            context.endPDFPage()
        }
        context.closePDF();return url
    }
    private static func line(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = point;CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
}

private final class SelectionProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ConversionProgress] = []
    var values: [ConversionProgress] { lock.withLock { events } }
    func append(_ event: ConversionProgress) { lock.withLock { events.append(event) } }
}
