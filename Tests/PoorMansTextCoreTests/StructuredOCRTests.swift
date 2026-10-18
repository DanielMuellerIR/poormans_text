import Foundation
import XCTest
@testable import PoorMansTextCore

final class StructuredOCRTests: XCTestCase, @unchecked Sendable {
    private typealias Recognition = StructuredDocumentRecognition
    private let box = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
    private func recognition(_ paragraphs: [Recognition.Text], tables: [Recognition.Table] = [], lists: [Recognition.List] = [], fullText: String? = nil) -> Recognition {
        .init(documents: [.init(text: .init(text: fullText ?? paragraphs.map(\.text).joined(separator: "\n"), bounds: box),
            paragraphs: paragraphs, lists: lists, tables: tables)], languages: [])
    }
    private func text(_ value: String, x: CGFloat = 0.2, y: CGFloat = 0.5) -> Recognition.Text {
        .init(text: value, bounds: CGRect(x: x, y: y, width: 0.15, height: 0.05))
    }

    func testTablePreservesEqualValuesBlanksSpansAndEscapesSourceMarkup() throws {
        let paragraphs = [text("42"), text("42", x: 0.5), text("<img>|[link](url)", y: 0.3)]
        let table = Recognition.Table(bounds: box, cells: [
            .init(rows: 0...0, columns: 0...0, text: paragraphs[0]),
            .init(rows: 0...0, columns: 1...1, text: paragraphs[1]),
            .init(rows: 1...2, columns: 0...0, text: paragraphs[2]),
            .init(rows: 1...1, columns: 1...1, text: text("")),
            .init(rows: 2...2, columns: 1...1, text: text(""))])
        let page = try StructuredOCRRendering.render(recognition(paragraphs, tables: [table]))
        XCTAssertTrue(page.flattenedSpans)
        XCTAssertEqual(page.blocks.count, 1)
        XCTAssertEqual(page.markdown.components(separatedBy: "42").count - 1, 2)
        XCTAssertTrue(page.markdown.contains("\\<img\\>\\|\\[link\\]\\(url\\)"), page.markdown)
        XCTAssertEqual(page.markdown.components(separatedBy: "\n").count, 5)
        XCTAssertEqual(page.markdown.components(separatedBy: "<img").count - 1, 1)
        XCTAssertTrue(page.markdown.hasSuffix("|  |  |"))
    }

    func testMultilineNumberedItemCannotInjectMarkdownStructure() throws {
        let body = "first\n# Heading\n<script>"
        let paragraph = text("12. " + body)
        let list = Recognition.List(bounds: box, items: [.init(text: text(body), marker: "12. ", markerKind: .decimal)])
        let page = try StructuredOCRRendering.render(recognition([paragraph], lists: [list]))
        XCTAssertTrue(page.markdown.hasPrefix("12. first\n    \\# Heading"), page.markdown)
        XCTAssertFalse(page.markdown.contains("\n# Heading"))
        XCTAssertFalse(page.markdown.contains("<script>"))
    }

    func testMissingTextOverlappingStructuresAndHugeSparseGridFallBack() throws {
        let paragraph = text("keep all")
        XCTAssertThrowsError(try StructuredOCRRendering.render(recognition([paragraph], fullText: "keep all additional")))
        let table = Recognition.Table(bounds: box, cells: [.init(rows: 0...0, columns: 0...0, text: paragraph)])
        XCTAssertThrowsError(try StructuredOCRRendering.render(recognition([paragraph], tables: [table, table])))
        let huge = Recognition.Table(bounds: box, cells: [.init(rows: 0...1023, columns: 0...1023, text: paragraph)])
        XCTAssertThrowsError(try StructuredOCRRendering.render(recognition([paragraph], tables: [huge])))
        let invalid = Recognition.Text(text: "keep all", bounds: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1))
        XCTAssertThrowsError(try StructuredOCRRendering.render(recognition([invalid])))
        let duplicated = recognition([paragraph])
        XCTAssertThrowsError(try StructuredOCRRendering.render(.init(documents: duplicated.documents + duplicated.documents, languages: [])))
    }

    func testListReplacesItsParagraphsOnceAndKeepsSurroundingOrder() throws {
        let paragraphs = [text("before", y: 0.9), text("• first", y: 0.6), text("• second", y: 0.4), text("after", y: 0.05)]
        let list = Recognition.List(bounds: box, items: [
            .init(text: text("first", y: 0.6), marker: "• ", markerKind: .bullet),
            .init(text: text("second", y: 0.4), marker: "• ", markerKind: .bullet)])
        let page = try StructuredOCRRendering.render(recognition(paragraphs, lists: [list]))
        XCTAssertEqual(page.markdown, "before\n\n- first\n- second\n\nafter")
    }

    func testUnavailableErrorsAndUnsafeStructureRunStandardExactlyOnce() throws {
        let errors: [Error] = [VisionDocumentRecognizer.RecognitionError.unavailable,
            VisionDocumentRecognizer.RecognitionError.unsupportedLanguages(["ru"]),
            VisionDocumentRecognizer.RecognitionError.resultTooLarge,
            VisionDocumentRecognizer.RecognitionError.recognitionFailed("synthetic")]
        for error in errors {
            var calls = 0
            let result = try DocumentOCR.recognize(method: .structured, structured: { throw error }, standard: {
                calls += 1; return .init(text: "original", lines: [])
            })
            XCTAssertEqual(calls, 1)
            XCTAssertNil(result.structured)
            XCTAssertEqual(result.markdown, "original")
            XCTAssertEqual(result.diagnostics.map(\.code), ["ocr.structuredFallback"])
        }
        let result = try DocumentOCR.recognize(method: .structured, structured: { self.recognition([self.text("part")], fullText: "part missing") }, standard: { .init(text: "part missing", lines: []) })
        XCTAssertEqual(result.markdown, "part missing")
        XCTAssertEqual(result.diagnostics.first?.code, "ocr.structuredFallback")
        XCTAssertThrowsError(try DocumentOCR.recognize(method: .structured, structured: { throw CancellationError() }, standard: { XCTFail("Cancellation fell back"); return .init(text: "", lines: []) }))
        do {
            _ = try DocumentOCR.recognize(method: .structured, structured: { throw VisionDocumentRecognizer.RecognitionError.unavailable }, standard: { throw VisionDocumentRecognizer.RecognitionError.recognitionFailed("synthetic") })
            XCTFail("Both OCR failures were swallowed")
        } catch {
            XCTAssertEqual((error as? DocumentOCR.FallbackFailure)?.diagnostic.code, "ocr.structuredFallback")
        }
        let standard = try DocumentOCR.recognize(method: .standard, structured: { XCTFail("Default entered structured OCR"); return self.recognition([]) }, standard: { .init(text: "default", lines: []) })
        XCTAssertEqual(standard.markdown, "default")
        XCTAssertTrue(standard.diagnostics.isEmpty)
    }

    func testPDFMergeKeepsDigitalTextAndRejectsConflictsWithoutDuplicatingFallback() throws {
        let bounds = CGRect(x: 10, y: 20, width: 1000, height: 1000)
        let header = PDFTextLine(text: "Digital original", bounds: CGRect(x: 110, y: 920, width: 300, height: 50))
        let recognized = StructuredOCRPage(blocks: [.init(text: "Scan", markdown: "- Scan", bounds: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1))], flattenedSpans: false)
        XCTAssertEqual(try PDFStructuredOCRMerge.merge(recognized, original: [header], bounds: bounds), "Digital original\n\n- Scan")
        let conflict = StructuredOCRPage(blocks: [.init(text: "Wrong original", markdown: "Wrong original", bounds: CGRect(x: 0.1, y: 0.9, width: 0.3, height: 0.05))] + recognized.blocks, flattenedSpans: false)
        XCTAssertNil(try PDFStructuredOCRMerge.merge(conflict, original: [header], bounds: bounds))
        let standard = VisionTextRecognition(text: "Wrong original\nScan", lines: [
            .init(text: "Wrong original", recognized: "Wrong original", bounds: conflict.blocks[0].bounds),
            .init(text: "Scan", recognized: "Scan", bounds: recognized.blocks[0].bounds)])
        let supplement = try PDFStructuredOCRMerge.supplementaryLines(standard, original: [header], bounds: bounds)
        XCTAssertTrue(supplement.conflict)
        XCTAssertEqual(supplement.lines.map(\.text), ["Scan"])
        let uncertain = [PDFTextLine(text: "Digital original", bounds: bounds)]
        XCTAssertNil(try PDFStructuredOCRMerge.merge(recognized, original: uncertain, bounds: bounds))
        XCTAssertThrowsError(try PDFStructuredOCRMerge.supplementaryLines(standard, original: uncertain, bounds: bounds))
        let unpositioned = [PDFTextLine(text: "Digital original", bounds: .zero)]
        XCTAssertThrowsError(try PDFStructuredOCRMerge.supplementaryLines(standard, original: unpositioned, bounds: bounds))
        let wider = VisionTextRecognition(text: "Digital original plus scan", lines: [.init(text: "Digital original plus scan", bounds: CGRect(x: 0.1, y: 0.9, width: 0.6, height: 0.05))])
        XCTAssertThrowsError(try PDFStructuredOCRMerge.supplementaryLines(wider, original: [header], bounds: bounds))
        let spaced = [PDFTextLine(text: "a part", bounds: header.bounds)]
        let joined = StructuredOCRPage(blocks: [.init(text: "apart", markdown: "apart", bounds: conflict.blocks[0].bounds)], flattenedSpans: false)
        XCTAssertNil(try PDFStructuredOCRMerge.merge(joined, original: spaced, bounds: bounds))
        let wrapped = StructuredOCRPage(blocks: [.init(text: "a\npart", markdown: "a\npart", bounds: conflict.blocks[0].bounds)], flattenedSpans: false)
        XCTAssertEqual(try PDFStructuredOCRMerge.merge(wrapped, original: spaced, bounds: bounds), "a\npart")
    }

    func testPDFSpatialBudgetAndCancellationPreserveOriginalInsteadOfEnteringQuadraticWork() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let original = Array(repeating: PDFTextLine(text: "original", bounds: CGRect(x: 100, y: 100, width: 100, height: 20)), count: 1001)
        let block = StructuredOCRPage.Block(text: "scan", markdown: "scan", bounds: box)
        let page = StructuredOCRPage(blocks: Array(repeating: block, count: 1000), flattenedSpans: false)
        XCTAssertNil(try PDFStructuredOCRMerge.merge(page, original: original, bounds: bounds))
        let recognition = VisionTextRecognition(text: "scan", lines: Array(repeating: .init(text: "scan", bounds: box), count: 1000))
        XCTAssertThrowsError(try PDFStructuredOCRMerge.supplementaryLines(recognition, original: original, bounds: bounds))
        let token = ConversionCancellationToken(); token.cancel()
        try ConversionExecution.$current.withValue(.init(cancellation: token, progress: nil, processTimeout: nil)) {
            XCTAssertThrowsError(try PDFStructuredOCRMerge.merge(page, original: [], bounds: bounds))
            XCTAssertThrowsError(try PDFStructuredOCRMerge.supplementaryLines(recognition, original: [], bounds: bounds))
        }
    }

    func testBridgeCancellationReleasesWaiterAndPreservesNextPermit() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires structured OCR executor") }
        let gate = OCRConcurrencyGate()
        let entered = expectation(description: "Gate holder entered")
        let released = expectation(description: "Gate holder released")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? gate.withPermit {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            released.fulfill()
        }
        defer { release.signal() }
        await fulfillment(of: [entered], timeout: 2)
        let token = ConversionCancellationToken()
        let waiterStarted = expectation(description: "Bridge task started")
        let task = Task.detached {
            try ConversionExecution.$current.withValue(.init(cancellation: token, progress: nil, processTimeout: nil)) {
                try OCRAsyncBridge.run {
                    waiterStarted.fulfill()
                    return try await gate.withAsyncPermit { XCTFail("Cancelled waiter entered OCR"); return 0 }
                }
            }
        }
        await fulfillment(of: [waiterStarted], timeout: 2)
        token.cancel()
        do { _ = try await task.value; XCTFail("Cancelled conversion succeeded") }
        catch { guard case ConversionError.cancelled = error else { return XCTFail("\(error)") } }
        release.signal()
        await fulfillment(of: [released], timeout: 2)
        let next = try await gate.withAsyncPermit { 42 }
        XCTAssertEqual(next, 42)
    }

    func testSynchronousBridgeRunsFromCooperativeTasksAndPropagatesContext() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires task executor available to structured OCR") }
        let total = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let token = ConversionCancellationToken()
                    return try ConversionExecution.$current.withValue(.init(cancellation: token, progress: nil, processTimeout: nil)) {
                        try OCRAsyncBridge.run {
                            XCTAssertTrue(ConversionExecution.current?.cancellation === token)
                            try await Task.sleep(for: .milliseconds(2))
                            return index
                        }
                    }
                }
            }
            var sum = 0
            for try await value in group { sum += value }
            return sum
        }
        XCTAssertEqual(total, 276)
    }
}
