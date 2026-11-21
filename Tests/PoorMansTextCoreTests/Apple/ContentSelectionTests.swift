import AppIntents
import AppKit
import Foundation
import XCTest
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class ContentSelectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTContentSelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    @MainActor private func model() -> AppModel { AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!) }
    @MainActor private func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.isConverting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isConverting)
    }
    @MainActor func testSelectionIsNotStoredInPreferencesOrTransferredToBatchOrService() async throws {
        let input = try PDFSelectionFixture.create(in: root, texts: ["FirstMarker", "SecondMarker", "ThirdMarker"])
        let identity = try DocumentConverter().inspectPDFContents(input).sourceIdentity
        let app = model(), selected = root.appendingPathComponent("selected"), complete = root.appendingPathComponent("complete")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: false)
        app.destinationFolder = selected; app.pdfTextRecognition = .disabled
        app.convertSelection(input, selection: .pdf(try IndexSelection("2")), identity: identity)
        try await wait(app)
        let text = try String(contentsOf: XCTUnwrap(app.selectedResult).markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("SecondMarker")); XCTAssertFalse(text.contains("FirstMarker"))
        XCTAssertNil(app.conversionOptions.pdfPages)
        app.destinationFolder = complete
        let csv = root.appendingPathComponent("batch.csv")
        try Data("name\nBatchMarker\n".utf8).write(to: csv)
        app.convert([input, csv]); try await wait(app)
        guard case .batchFinished(let items) = app.state else { return XCTFail("Expected batch") }
        XCTAssertEqual(items.compactMap(\.result).count, 2)
        let full = try String(contentsOf: XCTUnwrap(items.first?.result).markdownFile, encoding: .utf8)
        for marker in ["FirstMarker", "SecondMarker", "ThirdMarker"] { XCTAssertEqual(full.components(separatedBy: marker).count - 1, 1) }
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        app.convertRichText(.init(kind: .rtf, data: Data("{\\rtf1\\ansi ServiceMarker}".utf8)), to: pasteboard)
        try await wait(app)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("ServiceMarker") == true)
    }
    @MainActor func testCollisionRetryRetainsBindingButNewImportDoesNot() async throws {
        let input = try PDFSelectionFixture.create(in: root, texts: ["FirstMarker", "SecondMarker"])
        let identity = try DocumentConverter().inspectPDFContents(input).sourceIdentity
        let app = model(); app.pdfTextRecognition = .disabled
        let occupied = DocumentConverter.defaultOutputDirectory(for: input)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let sentinel = occupied.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
        app.convertSelection(input, selection: .pdf(try IndexSelection("2")), identity: identity); try await wait(app)
        guard case .failed = app.state else { return XCTFail("Expected collision") }
        app.destinationOverrides[input.path] = root.appendingPathComponent("retry")
        app.retryFailed(); try await wait(app)
        let text = try String(contentsOf: XCTUnwrap(app.selectedResult).markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("SecondMarker")); XCTAssertFalse(text.contains("FirstMarker"))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        app.destinationFolder = root
        app.destinationOverrides[input.path] = root.appendingPathComponent("ignored")
        app.convert(input); try await wait(app)
        guard case .failed = app.state else { return XCTFail("Expected unchanged occupied destination") }
    }
    @MainActor func testCancelledAndReloadedOverviewCannotDeliverLateState() async throws {
        let input = try PDFSelectionFixture.create(in: root, texts: ["FirstMarker", "SecondMarker"])
        let state = ContentSelectionModel(input: input)
        state.load(); state.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(state.overview); XCTAssertNil(state.error); XCTAssertFalse(state.isLoading)
        state.load()
        let deadline = Date().addingTimeInterval(10)
        while state.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .pdf(let summary) = state.overview else { return XCTFail("Expected PDF overview") }
        XCTAssertEqual(summary.pageCount, 2); XCTAssertNotNil(summary.sourceIdentity.sha256)
    }
    @MainActor func testShortcutModesRejectConflictingAndForeignSelectionParameters() async throws {
        let intent = ConvertDocumentIntent()
        XCTAssertNil(try intent.contentSelection())
        intent.presentationNotes = .include
        XCTAssertEqual(try intent.contentSelection(), .presentation(.init(includeNotes: true)))
        intent.pdfPages = "2"
        XCTAssertThrowsError(try intent.contentSelection())
        intent.presentationNotes = .documentDefault
        XCTAssertEqual(try intent.contentSelection(), .pdf(try IndexSelection("2")))
        intent.pdfPages = ""; intent.sheetNames = ["Comma, exact name", "Other"]
        XCTAssertEqual(try intent.contentSelection(), .spreadsheet(try SpreadsheetSelection(sheets: .names(["Comma, exact name", "Other"]))))
        intent.sheetSelection = .visible
        XCTAssertThrowsError(try intent.contentSelection())
        intent.sheetNames = []; intent.sheetIndices = "1"
        XCTAssertThrowsError(try intent.contentSelection())
        intent.sheetIndices = ""; intent.sheetSelection = .documentDefault; intent.presentationNotes = .exclude
        let input = root.appendingPathComponent("input.csv")
        try Data("name\nKeepMarker\n".utf8).write(to: input)
        intent.document = IntentFile(fileURL: input); intent.destinationFolder = IntentFile(fileURL: root)
        do { _ = try await intent.perform(); XCTFail("Expected format rejection") } catch { XCTAssertTrue(error.localizedDescription.contains("presentation selection"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentConverter.defaultOutputDirectory(for: input).path))
    }
    @MainActor func testSpreadsheetSelectionAndShortcutRangesUseOriginalIndicesInAllThreeFormats() async throws {
        for input in try SpreadsheetSelectionFixture.create(in: root) {
            let original = try Data(contentsOf: input)
            guard case .spreadsheet(let overview) = try ContentOverview.read(input, cancellation: .init()) else { return XCTFail("Expected workbook") }
            XCTAssertEqual(overview.sheets.map(\.index), [1, 2, 3])
            let app = model(), destination = root.appendingPathComponent(input.pathExtension + "-app")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            app.destinationFolder = destination
            app.convertSelection(input, selection: .spreadsheet(try SpreadsheetSelection(sheets: .indices(IndexSelection("2")), ranges: [SpreadsheetCellRange("C2:D2")])), identity: overview.sourceIdentity)
            try await wait(app)
            let result = try XCTUnwrap(app.selectedResult), text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for value in ["2203", "2204"] { XCTAssertEqual(text.components(separatedBy: value).count - 1, 1, text) }
            XCTAssertFalse(text.contains("1203")); XCTAssertFalse(text.contains("3203")); XCTAssertFalse(text.contains("2205"))
            XCTAssertTrue(result.sourceMappings.contains { $0.source.sheetIndex == 2 && $0.source.cell == "C2" })
            let intent = ConvertDocumentIntent()
            intent.document = IntentFile(fileURL: input); intent.destinationFolder = IntentFile(fileURL: root)
            intent.sheetIndices = "2"; intent.cellRanges = "C2:D2"
            let converted = try await intent.perform(), output = try XCTUnwrap(try XCTUnwrap(converted.value).first)
            let folder = try XCTUnwrap(URL(string: output))
            let shortcutText = try String(contentsOf: folder.appendingPathComponent("selection.md"), encoding: .utf8)
            XCTAssertEqual(text, shortcutText)
            XCTAssertEqual(try Data(contentsOf: input), original)
            try FileManager.default.removeItem(at: folder)
        }
    }

    @MainActor func testPDFAndEPUBShortcutSelectionsKeepOnlySelectedMarkers() async throws {
        let pdf = try PDFSelectionFixture.create(in: root, texts: ["FirstMarker", "SecondMarker", "ThirdMarker"])
        let epub = try EPUBSelectionFixture.create(in: root)
        for input in [pdf, epub] {
            let original = try Data(contentsOf: input), intent = ConvertDocumentIntent()
            intent.document = IntentFile(fileURL: input); intent.destinationFolder = IntentFile(fileURL: root)
            if input == pdf { intent.pdfPages = "2"; intent.pdfOCR = .disabled } else { intent.epubChapters = "2" }
            let converted = try await intent.perform()
            let folder = try XCTUnwrap(URL(string: XCTUnwrap(converted.value?.first)))
            let text = try String(contentsOf: folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".md"), encoding: .utf8)
            let selected = input == pdf ? "SecondMarker" : "AlphaMarker"
            XCTAssertEqual(text.components(separatedBy: selected).count - 1, 1)
            for excluded in input == pdf ? ["FirstMarker", "ThirdMarker"] : ["BetaMarker", "GammaMarker"] { XCTAssertFalse(text.contains(excluded)) }
            if input == epub {
                let preview = RenderedMarkdownPreview.render(text, assets: nil)
                XCTAssertFalse(preview.hasLiteralHTML, text)
                XCTAssertTrue(preview.html.contains("id=\"pmt-epub-chapter-2\""))
            }
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    @MainActor func testPresentationAppAndShortcutSelectionsIncludeAndExcludeNotes() async throws {
        for format in ["pptx", "odp"] {
            let input = try ContentSelectionFixture.presentation(in: root, format: format)
            let original = try Data(contentsOf: input)
            guard case .presentation(let overview) = try ContentOverview.read(input, cancellation: .init()) else { return XCTFail("Expected presentation") }
            XCTAssertEqual(overview.slides.map(\.number), [1, 2]); XCTAssertTrue(overview.slides[1].hasNotes)
            for include in [true, false] {
                let app = model(), destination = root.appendingPathComponent(format + String(include))
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                app.destinationFolder = destination
                app.convertSelection(input, selection: .presentation(.init(slides: try IndexSelection("2"), includeNotes: include)), identity: overview.sourceIdentity)
                try await wait(app)
                let result = try XCTUnwrap(app.selectedResult), text = try String(contentsOf: result.markdownFile, encoding: .utf8)
                XCTAssertEqual(text.components(separatedBy: "SecondMarker").count - 1, 1)
                XCTAssertFalse(text.contains("FirstMarker")); XCTAssertEqual(text.contains("NotesMarker"), include)
                XCTAssertTrue(result.sourceMappings.allSatisfy { $0.source.slide == 2 })
                let intent = ConvertDocumentIntent()
                intent.document = IntentFile(fileURL: input); intent.destinationFolder = IntentFile(fileURL: root)
                intent.slides = "2"; intent.presentationNotes = include ? .include : .exclude
                let converted = try await intent.perform(), folder = try XCTUnwrap(URL(string: XCTUnwrap(converted.value?.first)))
                XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("presentation.md"), encoding: .utf8), text)
                try FileManager.default.removeItem(at: folder)
            }
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    @MainActor func testParsingValidatesRangesAndEmptySelections() throws {
        XCTAssertNil(try ContentSelectionParsing.indices(" \n"))
        XCTAssertEqual(try ContentSelectionParsing.ranges("A1:C8, E2").map(\.description), ["A1:C8", "E2"])
        XCTAssertThrowsError(try ContentSelectionParsing.ranges("A1,,C2"))
        XCTAssertThrowsError(try ContentSelectionParsing.requiredIndices("", count: 3))
        XCTAssertThrowsError(try ContentSelectionParsing.requiredIndices("4", count: 3))
        XCTAssertNotEqual(ComparisonNavigation.label(.init(sheet: "Same", sheetIndex: 1)), ComparisonNavigation.label(.init(sheet: "Same", sheetIndex: 2)))
    }
}

private enum ContentSelectionFixture {
    static func presentation(in root: URL, format: String) throws -> URL {
        let source = root.appendingPathComponent("presentation." + format)
        func entry(_ name: String, _ value: String) -> ZIPFixtureBuilder.Entry { .init(name: name, content: Data(value.utf8)) }
        let entries: [ZIPFixtureBuilder.Entry]
        if format == "odp" {
            let xml = """
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"><office:body><office:presentation>
            <draw:page draw:name="First"><draw:text-box><text:p>FirstMarker</text:p></draw:text-box></draw:page>
            <draw:page draw:name="Second"><draw:text-box><text:p>SecondMarker</text:p></draw:text-box><presentation:notes><text:p>NotesMarker</text:p></presentation:notes></draw:page>
            </office:presentation></office:body></office:document-content>
            """
            entries = [entry("mimetype", "application/vnd.oasis.opendocument.presentation"), entry("content.xml", xml)]
        } else {
            let p = "http://schemas.openxmlformats.org/presentationml/2006/main", a = "http://schemas.openxmlformats.org/drawingml/2006/main", r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships", rel = "http://schemas.openxmlformats.org/package/2006/relationships"
            func slide(_ text: String) -> String { "<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>" }
            entries = [
                entry("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/></Types>"),
                entry("ppt/presentation.xml", "<p:presentation xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:sldIdLst><p:sldId id=\"1\" r:id=\"first\"/><p:sldId id=\"2\" r:id=\"second\"/></p:sldIdLst></p:presentation>"),
                entry("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"first\" Type=\"\(r)/slide\" Target=\"slides/first.xml\"/><Relationship Id=\"second\" Type=\"\(r)/slide\" Target=\"slides/second.xml\"/></Relationships>"),
                entry("ppt/slides/first.xml", slide("FirstMarker")), entry("ppt/slides/second.xml", slide("SecondMarker")),
                entry("ppt/slides/_rels/second.xml.rels", "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"notes\" Type=\"\(r)/notesSlide\" Target=\"../notesSlides/second.xml\"/></Relationships>"),
                entry("ppt/notesSlides/second.xml", "<p:notes xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>NotesMarker</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>")
            ]
        }
        try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
        return source
    }
}
