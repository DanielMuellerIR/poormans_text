import AppKit
import CoreGraphics
import Darwin
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import PoorMansTextCore

final class VisionDocumentRecognizerTests: XCTestCase, @unchecked Sendable {
    func testUnavailableSystemAndIndependentLanguageCapabilities() throws {
        for major in [13, 15, 25] {
            XCTAssertThrowsError(try VisionDocumentRecognizer.supportedLanguages(systemVersion: .init(majorVersion: major, minorVersion: 9, patchVersion: 0))) {
                XCTAssertEqual($0 as? VisionDocumentRecognizer.RecognitionError, .unavailable)
            }
        }
        guard #available(macOS 26, *) else { return }
        let supported = try VisionDocumentRecognizer.supportedLanguages()
        XCTAssertFalse(supported.isEmpty)
        let resolved = try VisionDocumentRecognizer.resolveLanguages(["de", "en-US", "de-DE"], supported: supported)
        XCTAssertEqual(Set(resolved), ["de-Latn-DE", "en-Latn-US"])
        XCTAssertEqual(try VisionDocumentRecognizer.resolveLanguages([], supported: supported), [])
        for languages in [["zz"], [""], ["de_DE"], Array(repeating: "en", count: 9)] {
            XCTAssertThrowsError(try VisionDocumentRecognizer.resolveLanguages(languages, supported: supported))
        }
    }

    func testPixelBudgetRejectsDimensionsBeforeRecognition() throws {
        try VisionDocumentRecognizer.validateInput(width: 4_000, height: 4_000)
        for dimensions in [(0, 10), (10, 0), (-1, 10), (8_193, 1), (4_001, 4_000), (Int.max, Int.max)] {
            XCTAssertThrowsError(try VisionDocumentRecognizer.validateInput(width: dimensions.0, height: dimensions.1)) {
                XCTAssertEqual($0 as? VisionDocumentRecognizer.RecognitionError, .inputTooLarge)
            }
        }
    }

    func testRealListsAndBlankPageKeepDistinctTextViews() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26 Vision") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for fixture in try makeFixtures(in: root).filter({ ["bullet-list", "numbered-paragraphs"].contains($0.name) }) {
            let result = try await VisionDocumentRecognizer.recognize(in: loadImage(fixture.url))
            let lists = result.documents.flatMap(\.lists)
            XCTAssertEqual(lists.count, 1)
            XCTAssertEqual(lists.first?.items.count, 3)
            XCTAssertEqual(lists.first?.items.map(\.markerKind), Array(repeating: fixture.name == "bullet-list" ? .bullet : .decimal, count: 3))
            let expected = fixture.name == "bullet-list" ? fixture.expected : Array(fixture.expected[1...3])
            XCTAssertEqual(lists.first?.items.map(\.text.text), expected)
            XCTAssertEqual(evaluate(result.documents.map(\.text.text).joined(separator: "\n"), expected: fixture.expected).counts, Array(repeating: 1, count: fixture.expected.count))
        }
        let blank = try await VisionDocumentRecognizer.recognize(in: canvas {})
        XCTAssertTrue(blank.documents.allSatisfy { $0.text.text.isEmpty && $0.lists.isEmpty && $0.tables.isEmpty })
    }

    func testRealTableKeepsAllCellsAndSourceBytes() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26 Vision") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixtures(in: root).first!
        let bytes = try Data(contentsOf: fixture.url)
        let image = try loadImage(fixture.url)
        let result = try await VisionDocumentRecognizer.recognize(in: image, languages: ["en"])
        let cells = result.documents.flatMap(\.tables).flatMap(\.cells)
        XCTAssertEqual(cells.count, 9)
        for cell in fixture.cells {
            XCTAssertTrue(cells.contains { $0.rows == cell.row...cell.row && $0.columns == cell.column...cell.column && $0.text.text == cell.text }, "Missing cell \(cell)")
        }
        let text = result.documents.map(\.text.text).joined(separator: "\n")
        XCTAssertEqual(evaluate(text, expected: fixture.expected).counts, Array(repeating: 1, count: 9))
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        XCTAssertEqual(try JSONDecoder().decode(StructuredDocumentRecognition.self, from: JSONEncoder().encode(result)), result)
        let vertical = try canvas {
            table([["North", "42", "90"], ["", "42", "81"]])
            NSColor.white.setFill(); NSRect(x: 83, y: 1247, width: 334, height: 6).fill()
        }
        let verticalResult = try await VisionDocumentRecognizer.recognize(in: vertical)
        let verticalCells = verticalResult.documents.flatMap(\.tables).flatMap(\.cells)
        XCTAssertEqual(verticalCells.count, 5)
        XCTAssertEqual(verticalCells.filter { $0.text.text == "North" }.count, 1)
        XCTAssertEqual(verticalCells.filter { $0.text.text == "42" }.count, 2)
        XCTAssertTrue(verticalCells.contains { $0.rows == 0...1 && $0.columns == 0...0 && $0.text.text == "North" })
        let converted = try DocumentConverter().convert(.init(inputURL: fixture.url, destination: .temporary))
        defer { try? FileManager.default.removeItem(at: converted.outputDirectory) }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(converted.assets.first)), bytes)
        do {
            _ = try await VisionDocumentRecognizer.recognize(in: image, maximumResultBytes: 3)
            XCTFail("Result byte limit was ignored")
        } catch { XCTAssertEqual(error as? VisionDocumentRecognizer.RecognitionError, .resultTooLarge) }
        for limit in [0, VisionDocumentRecognizer.maximumResultBytes + 1] {
            do {
                _ = try await VisionDocumentRecognizer.recognize(in: image, maximumResultBytes: limit)
                XCTFail("Invalid byte limit was accepted")
            } catch { XCTAssertEqual(error as? VisionDocumentRecognizer.RecognitionError, .resultTooLarge) }
        }
        do {
            _ = try await VisionDocumentRecognizer.recognize(in: image, languages: ["zz"])
            XCTFail("Unsupported language was accepted")
        } catch { XCTAssertEqual(error as? VisionDocumentRecognizer.RecognitionError, .unsupportedLanguages(["zz"])) }
    }

    func testAPIErrorIsTypedAndPermitIsReleased() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26 Vision") }
        do {
            let _: [DocumentObservation] = try await VisionDocumentRecognizer.performWithPermit {
                try await RecognizeDocumentsRequest(.revision1).perform(on: Data([0]))
            }
            XCTFail("API error was swallowed")
        } catch {
            guard case .recognitionFailed = error as? VisionDocumentRecognizer.RecognitionError else { return XCTFail("\(error)") }
        }
        let value = try await VisionDocumentRecognizer.performWithPermit { 42 }
        XCTAssertEqual(value, 42)
    }

    func testTaskAndConversionCancellationDoNotEnterRecognition() async throws {
        let token = ConversionCancellationToken()
        token.cancel()
        do {
            let _: Int = try await ConversionExecution.$current.withValue(.init(cancellation: token, progress: nil, processTimeout: nil)) {
                try await VisionDocumentRecognizer.performWithPermit { XCTFail("Cancelled conversion entered"); return 0 }
            }
            XCTFail("Cancelled conversion succeeded")
        } catch { guard case ConversionError.cancelled = error else { return XCTFail("\(error)") } }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VisionDocumentRecognizer.performWithPermit { XCTFail("Cancelled task entered"); return 0 }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAsyncGateSharesSlotWithSynchronousOCRAndCancelsWaiter() async throws {
        let gate = OCRConcurrencyGate()
        let entered = expectation(description: "Async holder entered")
        let synchronousEntered = expectation(description: "Sync contender entered after holder")
        let synchronousStarted = expectation(description: "Sync contender started")
        let waiterStarted = expectation(description: "Waiter started while holder owns slot")
        let active = Flag(), release = Flag()
        defer { release.set(true) }
        let holder = Task {
            try await gate.withAsyncPermit {
                active.set(true)
                defer { active.set(false) }
                entered.fulfill()
                let deadline = ContinuousClock.now + .seconds(5)
                while !release.value, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(release.value, "Test holder reached its deadline")
                return 1
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let waiter = Task {
            waiterStarted.fulfill()
            return try await gate.withAsyncPermit { XCTFail("Cancelled waiter entered"); return 0 }
        }
        await fulfillment(of: [waiterStarted], timeout: 2)
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Cancelled waiter succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        DispatchQueue.global().async {
            synchronousStarted.fulfill()
            try? gate.withPermit {
                XCTAssertFalse(active.value, "Sync OCR overlapped async OCR")
                synchronousEntered.fulfill()
            }
        }
        await fulfillment(of: [synchronousStarted], timeout: 2)
        release.set(true)
        let held = try await holder.value
        XCTAssertEqual(held, 1)
        await fulfillment(of: [synchronousEntered], timeout: 2)
        let next = try await gate.withAsyncPermit { 2 }
        XCTAssertEqual(next, 2)
    }

    /// Qualitätsmessung: Schwächen sind Messwerte, keine nachträglich gelockerten
    /// Erwartungen. Die einfache Tabelle oben bleibt ein strikter Funktionstest.
    func testComparisonMatrix() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26 Vision") }
        let environment = ProcessInfo.processInfo.environment
        let savedRoot = environment["PMT_VISION_COMPARISON_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = try savedRoot ?? temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if savedRoot == nil { try? FileManager.default.removeItem(at: root) } }
        let engine = environment["PMT_VISION_ENGINE"] ?? "both"
        XCTAssertTrue(["both", "legacy", "structured"].contains(engine))
        let fixtures = try makeFixtures(in: root)
        var rows: [Measurement] = []
        for fixture in fixtures {
            let bytes = try Data(contentsOf: fixture.url)
            let hash = ConversionFileFingerprint.digest(bytes)
            let images: [CGImage]
            if fixture.url.pathExtension == "pdf" {
                let pdf = try XCTUnwrap(PDFDocument(url: fixture.url))
                images = try (0..<pdf.pageCount).map { try renderPDF(try XCTUnwrap(pdf.page(at: $0))) }
            } else { images = [try loadImage(fixture.url)] }
            for (index, image) in images.enumerated() {
                let expected = index == 0 ? fixture.expected : ["Second scan", "Local document", "Final sentence"]
                if engine != "structured" {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = try VisionTextRecognizer.recognize(in: image, orientation: fixture.orientation, languages: fixture.languages)
                    rows.append(.init(fixture: fixture.name, page: index + 1, engine: "legacy", sourceSHA256: hash, width: image.width, height: image.height, orientation: fixture.orientation.rawValue, languages: fixture.languages, seconds: elapsed(start), processPeakRSSBytes: peakRSS(), text: result.text, evaluation: evaluate(result.text, expected: expected), structured: nil, expectedCells: index == 0 ? fixture.cells : [], matchingCells: nil))
                }
                if engine != "legacy" {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = try await VisionDocumentRecognizer.recognize(in: image, orientation: fixture.orientation, languages: fixture.languages)
                    let text = result.documents.map(\.text.text).joined(separator: "\n")
                    let cells = result.documents.flatMap(\.tables).flatMap(\.cells)
                    let targets = index == 0 ? fixture.cells : []
                    let matching = targets.filter { target in cells.contains { $0.rows == target.row...(target.rowEnd ?? target.row) && $0.columns == target.column...(target.columnEnd ?? target.column) && $0.text.text == target.text } }.count
                    rows.append(.init(fixture: fixture.name, page: index + 1, engine: "structured", sourceSHA256: hash, width: image.width, height: image.height, orientation: fixture.orientation.rawValue, languages: fixture.languages, seconds: elapsed(start), processPeakRSSBytes: peakRSS(), text: text, evaluation: evaluate(text, expected: expected), structured: result, expectedCells: targets, matchingCells: matching))
                }
            }
            XCTAssertEqual(ConversionFileFingerprint.digest(try Data(contentsOf: fixture.url)), hash)
        }
        XCTAssertEqual(fixtures.count, 10)
        XCTAssertEqual(rows.count, engine == "both" ? 22 : 11)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: root.appendingPathComponent("measurements-\(engine).json"), options: .atomic)
        try encoder.encode(VisionDocumentRecognizer.supportedLanguages()).write(to: root.appendingPathComponent("supported-languages.json"), options: .atomic)
        if engine != "structured" {
            let pdf = try XCTUnwrap(fixtures.first { $0.name == "mixed-pdf" })
            let sourceBytes = try Data(contentsOf: pdf.url)
            let result = try DocumentConverter().convert(.init(inputURL: pdf.url, destination: .temporary, options: .init(conversionReport: true)))
            defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(evaluate(markdown, expected: pdf.expected + ["Second scan", "Local document", "Final sentence"]).counts, Array(repeating: 1, count: 15), markdown)
            XCTAssertEqual(try Data(contentsOf: pdf.url), sourceBytes)
            XCTAssertEqual(result.sourceIdentity?.sha256, ConversionFileFingerprint.digest(sourceBytes))
            let report = ["markdown": markdown, "sourceSHA256": ConversionFileFingerprint.digest(sourceBytes), "assetSHA256": try result.assets.map { ConversionFileFingerprint.digest(try Data(contentsOf: $0)) }.joined(separator: ",")]
            try encoder.encode(report).write(to: root.appendingPathComponent("existing-pdf-import.json"), options: .atomic)
        }
    }

    func testStructuredProductImportMatrixPreservesContentsCellsAndBytes() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26 Vision") }
        let saved = ProcessInfo.processInfo.environment["PMT_STRUCTURED_IMPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = try saved ?? temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if saved == nil { try? FileManager.default.removeItem(at: root) } }
        var measurements: [[String: Any]] = []
        for fixture in try makeFixtures(in: root) {
            var source = fixture.url
            if fixture.orientation != .up {
                source = root.appendingPathComponent("orientation.tiff")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.tiff.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, try loadImage(fixture.url), [kCGImagePropertyOrientation: fixture.orientation.rawValue] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            let bytes = try Data(contentsOf: source)
            let expected = fixture.expected + (source.pathExtension == "pdf" ? ["Second scan", "Local document", "Final sentence"] : [])
            for method in [OCRMethod.standard, .structured] {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try DocumentConverter().convert(.init(inputURL: source, destination: .temporary,
                    options: .init(ocrLanguages: fixture.languages, ocrMethod: method, conversionReport: true)))
                defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
                let seconds = elapsed(start)
                let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
                let evaluation = evaluate(markdown, expected: expected)
                XCTAssertEqual(evaluation.counts, Array(repeating: 1, count: expected.count), "\(fixture.name) / \(method): \(markdown)")
                if method == .structured {
                    XCTAssertTrue(evaluation.expectedOrder, "\(fixture.name): \(markdown)")
                    XCTAssertTrue(result.diagnostics.contains { $0.code == "ocr.structuredApplied" }, "\(fixture.name): \(result.diagnostics)")
                    let tableRows = markdown.components(separatedBy: "\n").filter { $0.hasPrefix("| ") }
                    for cell in fixture.cells {
                        let row = try XCTUnwrap(tableRows.dropFirst(cell.row + 2).first, fixture.name)
                        let columns = row.components(separatedBy: "|").dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
                        XCTAssertTrue(columns.indices.contains(cell.column), row)
                        if columns.indices.contains(cell.column) { XCTAssertEqual(columns[cell.column], cell.text, fixture.name) }
                    }
                    if fixture.name == "bullet-list" { XCTAssertTrue(markdown.contains("- Alpha orchard\n- Beta garden\n- Gamma meadow"), markdown) }
                    if fixture.name == "numbered-paragraphs" { XCTAssertTrue(markdown.contains("1. First action\n2. Second action\n3. Third action"), markdown) }
                }
                XCTAssertEqual(try Data(contentsOf: source), bytes)
                if source.pathExtension != "pdf" { XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), bytes) }
                XCTAssertEqual(result.sourceIdentity?.sha256, ConversionFileFingerprint.digest(bytes))
                let reportData = try Data(contentsOf: result.outputDirectory.appendingPathComponent("conversion-report.json"))
                let report = try JSONDecoder().decode(ConversionReport.self, from: reportData)
                XCTAssertEqual(report.options.ocrMethod, method)
                measurements.append(["fixture": fixture.name, "method": method.rawValue, "seconds": seconds,
                    "sourceSHA256": ConversionFileFingerprint.digest(bytes), "expected": expected,
                    "counts": evaluation.counts, "expectedOrder": evaluation.expectedOrder,
                    "expectedCells": fixture.cells.count, "markdown": markdown,
                    "diagnostics": result.diagnostics.map(\.code), "processPeakRSSBytes": peakRSS()])
            }
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("product-imports.json"), options: .atomic)
    }

    func testStructuredMixedPDFConflictPreservesInvisibleOriginalAndAddsNonoverlappingScan() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26 Vision") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("conflicting.pdf")
        let image = try canvas { draw("Wrong original", x: 100, y: 1350); draw("Additional scan", x: 100, y: 1100) }
        var box = CGRect(x: 0, y: 0, width: 1200, height: 1600)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Digital original" as NSString).draw(at: NSPoint(x: 100, y: 1350), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.clear])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: source)?.page(at: 0)?.string).contains("Digital original"))
        let bytes = try Data(contentsOf: source)
        for layout in [PDFLayout.automatic, .legacy] {
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .temporary, options: .init(ocrMethod: .structured, pdfLayout: layout)))
            defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(markdown.components(separatedBy: "Digital original").count - 1, 1, markdown)
            XCTAssertEqual(markdown.components(separatedBy: "Additional scan").count - 1, 1, markdown)
            XCTAssertFalse(markdown.contains("Wrong original"), markdown)
            XCTAssertTrue(result.diagnostics.contains { $0.code == "ocr.structuredFallback" })
            XCTAssertTrue(result.diagnostics.contains { $0.code == "pdf.ocrOriginalRetained" })
            XCTAssertFalse(result.diagnostics.contains { $0.code == "ocr.structuredApplied" })
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let ambiguous = root.appendingPathComponent("ambiguous.pdf")
        let wider = try canvas { draw("Digital original plus scan", x: 100, y: 1350) }
        let secondContext = try XCTUnwrap(CGContext(ambiguous as CFURL, mediaBox: &box, nil))
        secondContext.beginPDFPage(nil); secondContext.draw(wider, in: box)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: secondContext, flipped: false)
        ("Digital original" as NSString).draw(at: NSPoint(x: 100, y: 1350), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.clear])
        NSGraphicsContext.restoreGraphicsState()
        secondContext.endPDFPage(); secondContext.closePDF()
        let original = try Data(contentsOf: ambiguous)
        let destination = root.appendingPathComponent("ambiguous-output")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: ambiguous, destination: .directory(destination), options: .init(ocrMethod: .structured)))) {
            XCTAssertTrue($0.localizedDescription.contains("geometry limits"), "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
        XCTAssertEqual(try Data(contentsOf: ambiguous), original)
    }

    func testStructuredPDFOptionsRetainRecognizedPagesAndLeaveDisabledLegacyUnchanged() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26 Vision") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("repeated.pdf")
        let tableImage = try canvas { table([["Name", "Count"], ["Apples", "42"]]) }
        var box = CGRect(x: 0, y: 0, width: 1200, height: 1600)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw("Repeated header", x: 100, y: 1500)
            NSGraphicsContext.restoreGraphicsState()
            context.draw(tableImage, in: CGRect(x: 100, y: 100, width: 1000, height: 1100))
            context.endPDFPage()
        }
        context.closePDF()
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .temporary,
            options: .init(pdfTextRecognition: .always, ocrMethod: .structured, pdfRemoveHeadersFooters: true, pdfDehyphenate: true)))
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for token in ["Repeated header", "Name", "Count", "Apples", "42"] {
            XCTAssertEqual(markdown.components(separatedBy: token).count - 1, 2, markdown)
        }
        XCTAssertEqual(result.diagnostics.filter { $0.code == "ocr.structuredApplied" }.count, 2)
        XCTAssertEqual(result.diagnostics.filter { $0.code == "pdf.structuredLayoutRetained" }.count, 2)
        XCTAssertFalse(result.diagnostics.contains { $0.code == "pdf.repeatedMarginRemoved" })
        var outputs: [String] = []
        for method in [OCRMethod.standard, .structured] {
            let disabled = try DocumentConverter().convert(.init(inputURL: source, destination: .temporary,
                options: .init(pdfTextRecognition: .disabled, ocrMethod: method, pdfLayout: .legacy, pdfRemoveHeadersFooters: true)))
            defer { try? FileManager.default.removeItem(at: disabled.outputDirectory) }
            outputs.append(try String(contentsOf: disabled.markdownFile, encoding: .utf8))
            XCTAssertFalse(disabled.diagnostics.contains { $0.code.hasPrefix("ocr.") })
        }
        XCTAssertEqual(outputs[0], outputs[1])
    }

    func testStructuredAndStandardImportsInFourWorkerBatch() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26 Vision") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = Array(try makeFixtures(in: root).prefix(4))
        let requests = fixtures.enumerated().map { index, fixture in
            ConversionRequest(inputURL: fixture.url, destination: .temporary, options: .init(ocrMethod: index.isMultiple(of: 2) ? .structured : .standard))
        }
        let results = try BatchConverter().convert(requests, jobs: 4)
        XCTAssertEqual(results.count, 4)
        for (fixture, item) in zip(fixtures, results) {
            let result = try item.outcome.get()
            defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(evaluate(markdown, expected: fixture.expected).counts, Array(repeating: 1, count: fixture.expected.count))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), try Data(contentsOf: fixture.url))
        }
    }

    private struct ExpectedCell: Codable, CustomStringConvertible {
        let row: Int
        let column: Int
        let text: String
        var rowEnd: Int? = nil
        var columnEnd: Int? = nil
        var description: String { "[\(row),\(column)]=\(text)" }
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var value: Bool { lock.withLock { storage } }
        func set(_ value: Bool) { lock.withLock { storage = value } }
    }
    private struct Fixture {
        let name: String
        let url: URL
        let expected: [String]
        var cells: [ExpectedCell] = []
        var orientation: CGImagePropertyOrientation = .up
        var languages: [String] = ["en-US"]
    }
    private struct Evaluation: Codable {
        let expected: [String]
        let counts: [Int]
        let expectedOrder: Bool
    }
    private struct Measurement: Codable {
        let fixture: String
        let page: Int
        let engine: String
        let sourceSHA256: String
        let width: Int
        let height: Int
        let orientation: UInt32
        let languages: [String]
        let seconds: Double
        let processPeakRSSBytes: Int64
        let text: String
        let evaluation: Evaluation
        let structured: StructuredDocumentRecognition?
        let expectedCells: [ExpectedCell]
        let matchingCells: Int?
    }

    private func evaluate(_ text: String, expected: [String]) -> Evaluation {
        let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        var counts: [Int] = []
        var positions: [Int] = []
        for value in expected {
            var count = 0, search = normalized.startIndex..<normalized.endIndex
            while let range = normalized.range(of: value, range: search) {
                if count == 0 { positions.append(normalized.distance(from: normalized.startIndex, to: range.lowerBound)) }
                count += 1; search = range.upperBound..<normalized.endIndex
            }
            counts.append(count)
        }
        return .init(expected: expected, counts: counts, expectedOrder: positions.count == expected.count && zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
    }
    private func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000 }
    private func peakRSS() -> Int64 {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTVisionPrototype-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func loadImage(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func canvas(_ draw: () -> Void) throws -> CGImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 1600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 1600).fill()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.cgImage)
    }
    private func draw(_ text: String, x: Int, y: Int, size: CGFloat = 42) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
    }
    private func table(_ values: [[String]], grid: Bool = true) {
        if grid {
            NSColor.black.setStroke()
            for row in 0...values.count {
                let line = NSBezierPath(); line.lineWidth = 3
                line.move(to: NSPoint(x: 80, y: 1400 - row * 150)); line.line(to: NSPoint(x: 1100, y: 1400 - row * 150)); line.stroke()
            }
            for column in 0...3 {
                let line = NSBezierPath(); line.lineWidth = 3
                line.move(to: NSPoint(x: 80 + column * 340, y: 1400)); line.line(to: NSPoint(x: 80 + column * 340, y: 1400 - values.count * 150)); line.stroke()
            }
        }
        for (row, values) in values.enumerated() { for (column, value) in values.enumerated() { draw(value, x: 110 + column * 340, y: 1300 - row * 150) } }
    }
    private func save(_ image: CGImage, name: String, in root: URL, jpeg: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name + (jpeg ? ".jpg" : ".png"))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary : nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func makeFixtures(in root: URL) throws -> [Fixture] {
        let values = [["Item", "Count", "Price"], ["Apples", "12", "24"], ["Pears", "34", "56"]]
        let cells = values.enumerated().flatMap { row, values in values.enumerated().map { ExpectedCell(row: row, column: $0.offset, text: $0.element) } }
        let tableImage = try canvas { table(values) }
        var fixtures = [Fixture(name: "grid-table", url: try save(tableImage, name: "grid-table", in: root), expected: values.flatMap { $0 }, cells: cells)]
        let other = [["Name", "Units", "Total"], ["Oranges", "17", "38"], ["Peaches", "29", "64"]]
        let otherCells = other.enumerated().flatMap { row, values in values.enumerated().map { ExpectedCell(row: row, column: $0.offset, text: $0.element) } }
        fixtures.append(.init(name: "plain-table", url: try save(canvas { table(other, grid: false) }, name: "plain-table", in: root), expected: other.flatMap { $0 }, cells: otherCells))
        let merged = try canvas {
            table([["Shared", "", "Amount"], ["North", "", "73"], ["South", "", "85"]])
            NSColor.white.setFill(); NSRect(x: 417, y: 1253, width: 6, height: 144).fill()
        }
        let mergedCells = [
            ExpectedCell(row: 0, column: 0, text: "Shared", columnEnd: 1),
            ExpectedCell(row: 0, column: 2, text: "Amount"),
            ExpectedCell(row: 1, column: 0, text: "North"),
            ExpectedCell(row: 1, column: 1, text: ""),
            ExpectedCell(row: 1, column: 2, text: "73"),
            ExpectedCell(row: 2, column: 0, text: "South"),
            ExpectedCell(row: 2, column: 1, text: ""),
            ExpectedCell(row: 2, column: 2, text: "85")
        ]
        fixtures.append(.init(name: "merged-empty-table", url: try save(merged, name: "merged-empty-table", in: root), expected: ["Shared", "Amount", "North", "73", "South", "85"], cells: mergedCells))
        let bullets = ["Alpha orchard", "Beta garden", "Gamma meadow"]
        fixtures.append(.init(name: "bullet-list", url: try save(canvas { for (index, value) in bullets.enumerated() { draw("• " + value, x: 100, y: 1350 - index * 140) } }, name: "bullet-list", in: root), expected: bullets))
        let numbered = ["Opening paragraph", "First action", "Second action", "Third action", "Closing paragraph"]
        fixtures.append(.init(name: "numbered-paragraphs", url: try save(canvas {
            draw(numbered[0], x: 100, y: 1450)
            for index in 1...3 { draw("\(index). " + numbered[index], x: 100, y: 1350 - index * 100) }
            draw(numbered[4], x: 100, y: 700)
        }, name: "numbered-paragraphs", in: root), expected: numbered))
        let photoLines = ["Market report", "Fresh produce", "Local delivery", "Order complete"]
        let photo = try canvas {
            NSGradient(starting: .init(white: 0.97, alpha: 1), ending: .init(white: 0.72, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: 1200, height: 1600), angle: 35)
            let transform = AffineTransform(rotationByDegrees: 6); (transform as NSAffineTransform).concat()
            for (index, line) in photoLines.enumerated() { draw(line, x: 160, y: 1350 - index * 170) }
        }
        fixtures.append(.init(name: "photo-jpeg", url: try save(photo, name: "photo-jpeg", in: root, jpeg: true), expected: photoLines))
        let columns = ["Left opening", "Left middle", "Left ending", "Right opening", "Right middle", "Right ending"]
        fixtures.append(.init(name: "two-columns", url: try save(canvas {
            for index in 0..<3 { draw(columns[index], x: 80, y: 1350 - index * 150, size: 38); draw(columns[index + 3], x: 650, y: 1350 - index * 150, size: 38) }
        }, name: "two-columns", in: root), expected: columns))
        let pdfURL = root.appendingPathComponent("mixed-pdf.pdf")
        if !FileManager.default.fileExists(atPath: pdfURL.path) {
        var mediaBox = CGRect(x: 0, y: 0, width: 1200, height: 1600)
        let context = try XCTUnwrap(CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, value) in ["Digital heading", "Native paragraph", "Embedded footer"].enumerated() { draw(value, x: 100, y: 1500 - index * 85) }
        NSGraphicsContext.restoreGraphicsState()
        context.draw(tableImage, in: CGRect(x: 100, y: 100, width: 1000, height: 1100))
        context.endPDFPage(); context.beginPDFPage(nil)
        let second = try canvas { for (index, value) in ["Second scan", "Local document", "Final sentence"].enumerated() { draw(value, x: 100, y: 1300 - index * 170) } }
        context.draw(second, in: mediaBox); context.endPDFPage(); context.closePDF()
        }
        fixtures.append(.init(name: "mixed-pdf", url: pdfURL, expected: ["Digital heading", "Native paragraph", "Embedded footer"] + values.flatMap { $0 }, cells: cells))
        let german = ["Grüße aus Köln", "Äpfel und Öl", "Straße am Fluss"]
        fixtures.append(.init(name: "german", url: try save(canvas { for (index, value) in german.enumerated() { draw(value, x: 100, y: 1350 - index * 180) } }, name: "german", in: root), expected: german, languages: ["de-DE"]))
        let orientedLines = ["Rotation heading", "Upright reading", "Orientation ending"]
        let upright = try canvas { for (index, value) in orientedLines.enumerated() { draw(value, x: 100, y: 1350 - index * 180) } }
        let rotated = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        rotated.translateBy(x: 1600, y: 0); rotated.rotate(by: .pi / 2); rotated.draw(upright, in: CGRect(x: 0, y: 0, width: 1200, height: 1600))
        fixtures.append(.init(name: "orientation", url: try save(try XCTUnwrap(rotated.makeImage()), name: "orientation", in: root), expected: orientedLines, orientation: .right))
        return fixtures
    }
    private func renderPDF(_ page: PDFPage) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        page.draw(with: .mediaBox, to: context)
        return try XCTUnwrap(context.makeImage())
    }
}
