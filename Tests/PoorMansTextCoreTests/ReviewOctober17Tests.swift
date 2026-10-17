import Foundation
import XCTest
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class ReviewOctober17Tests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTReviewOctober17-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testNumericEPUBFragmentsKeepTheirTextLinksAndAsset() throws {
        let source = root.appendingPathComponent("numbers.epub")
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Numeric chapter</title></head><body><h1>Numeric chapter</h1><p><span id="number">123</span> and <span id="year">2026</span></p><p><a href="#number">Number link</a> and <a href="#year">Year link</a></p><p><img src="picture.png" alt="Picture"/></p></body></html>
        """
        let entries: [ZIPFixtureBuilder.Entry] = [
            .init(name: "mimetype", content: Data("application/epub+zip".utf8), isStored: true),
            .init(name: "META-INF/container.xml", content: Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)),
            .init(name: "package.opf", content: Data("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Numeric chapter</dc:title></metadata><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"image\" href=\"picture.png\" media-type=\"image/png\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>".utf8)),
            .init(name: "chapter.xhtml", content: Data(xhtml.utf8)),
            .init(name: "picture.png", content: try EPUBSelectionFixture.png())
        ]
        try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
        let original = try Data(contentsOf: source)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(layout == .textbundle ? "result.textbundle" : "result")), options: .init(outputLayout: layout, epubChapters: IndexSelection("1"), conversionReport: true)))
            let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(text.components(separatedBy: "123").count - 1, 1)
            XCTAssertEqual(text.components(separatedBy: "2026").count - 1, 1)
            XCTAssertTrue(text.contains("[Number link](#pmt-epub-chapter-1-anchor-1)"), text)
            XCTAssertTrue(text.contains("[Year link](#pmt-epub-chapter-1-anchor-2)"), text)
            XCTAssertFalse(text.contains("PMTEPUB"))
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), try EPUBSelectionFixture.png())
            XCTAssertEqual(result.sourceMappings.map(\.source.chapter), [1])
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    @MainActor func testBoundSelectionRejectsDirectoryReplacementBeforeConversionAndRetry() async throws {
        for retry in [false, true] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let input = try PDFSelectionFixture.create(in: directory, texts: ["OriginalMarker", "SelectedMarker"])
            let original = try Data(contentsOf: input)
            let identity = try DocumentConverter().inspectPDFContents(input).sourceIdentity
            let output = directory.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let app = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            app.destinationFolder = output; app.pdfTextRecognition = .disabled
            if retry {
                let occupied = output.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-markdown")
                try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
                try Data("KeepExisting".utf8).write(to: occupied.appendingPathComponent("sentinel"))
                app.convertSelection(input, selection: .pdf(try IndexSelection("2")), identity: identity)
                try await wait(app)
                guard case .failed = app.state else { return XCTFail("Expected occupied output") }
                app.destinationOverrides[input.path] = output.appendingPathComponent("retry-result")
            }
            let archived = directory.appendingPathComponent("original.pdf")
            try FileManager.default.moveItem(at: input, to: archived)
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
            let child = input.appendingPathComponent("child.csv"), childBytes = Data("name\nUnexpectedChildMarker\n".utf8)
            try childBytes.write(to: child)
            if retry { app.retryFailed() }
            else { app.convertSelection(input, selection: .pdf(try IndexSelection("2")), identity: identity) }
            try await wait(app)
            guard case .failed = app.state else { XCTFail("Changed selection became a folder import; retry=\(retry)"); continue }
            let outputs = try FileManager.default.contentsOfDirectory(atPath: output.path)
            XCTAssertEqual(outputs.count, retry ? 1 : 0, "\(outputs)")
            XCTAssertFalse(outputs.contains("child-markdown")); XCTAssertFalse(outputs.contains("retry-result"))
            if retry { XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-markdown/sentinel")), Data("KeepExisting".utf8)) }
            XCTAssertEqual(try Data(contentsOf: child), childBytes)
            XCTAssertEqual(try Data(contentsOf: archived), original)
            app.convert(input)
            try await wait(app)
            let complete = try String(contentsOf: output.appendingPathComponent("child-markdown/child.md"), encoding: .utf8)
            XCTAssertEqual(complete.components(separatedBy: "UnexpectedChildMarker").count - 1, 1)
        }
    }

    func testSameNamedSheetsKeepExactAndCoarseCellsInTheChosenSheet() throws {
        let mappings = [
            ConversionSourceMapping(source: .init(sheet: "Same", cell: "A1", sheetIndex: 1), output: .init(file: "text.md", utf8Offset: 10, utf8Length: 5)),
            ConversionSourceMapping(source: .init(sheet: "Same", cell: "B2", sheetIndex: 2), output: .init(file: "text.md", utf8Offset: 20, utf8Length: 5)),
            ConversionSourceMapping(source: .init(sheet: "Same", cell: "C3", sheetIndex: 1), output: .init(file: "text.md", utf8Offset: 30, utf8Length: 5)),
            ConversionSourceMapping(source: .init(sheet: "Same", cell: "C3", sheetIndex: 2), output: .init(file: "text.md", utf8Offset: 40, utf8Length: 5))
        ]
        let coarse = try XCTUnwrap(ComparisonNavigation.target(for: .init(sheet: "Same", cell: "B2", sheetIndex: 1), mappings: mappings))
        XCTAssertFalse(coarse.exact); XCTAssertEqual(coarse.range.utf8Offset, 10)
        for index in 1...2 {
            let exact = try XCTUnwrap(ComparisonNavigation.target(for: .init(sheet: "Same", cell: "C3", sheetIndex: index), mappings: mappings))
            XCTAssertTrue(exact.exact); XCTAssertEqual(exact.range.utf8Offset, index == 1 ? 30 : 40)
        }
    }

    func testManyInlineBreaksAndGeneratedAnchorsPreserveContent() {
        for count in [1_000, 2_000, 4_000] {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = RenderedMarkdownPreview.render(String(repeating: "x<br>", count: count), assets: nil)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            print("PMT_INLINE_BENCHMARK \(count) \(seconds)")
            XCTAssertEqual(result.html.components(separatedBy: "<br>").count - 1, count)
            XCTAssertFalse(result.limited)
        }
        let source = (1...1_000).map { "x<a id=\"pmt-epub-chapter-1-anchor-\($0)\"></a>" }.joined()
        let result = RenderedMarkdownPreview.render(source, assets: nil)
        XCTAssertEqual(result.html.components(separatedBy: "<span id=\"pmt-epub-chapter-1-anchor-").count - 1, 1_000)
        XCTAssertFalse(result.html.contains("&lt;/a&gt;")); XCTAssertFalse(result.limited)
    }

    func testPreciseDayFractionsKeepTheirDateTimeAndDurationBeforeMidnight() {
        let cases = [("46311.999999999999999999", "yyyy-mm-dd hh:mm", "2026-10-16 23:59"),
                     ("0.999999999999999999", "hh:mm", "23:59"),
                     ("0.99999999999999999999999999999999999999", "hh:mm", "23:59"),
                     ("1.999999999999999999", "[h]:mm", "47:59")]
        for (value, format, expected) in cases {
            let result = SpreadsheetNumberFormat(code: format).format(value)
            XCTAssertEqual(result.text, expected, "\(value) / \(format)")
            XCTAssertNil(result.issue)
        }
    }

    func testRealXLSXPreservesPreciseDateTimeAndElapsedMinutesInBothRenderings() throws {
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let parts = [
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/></Types>",
            "xl/workbook.xml": "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(office)\"><sheets><sheet name=\"Values\" sheetId=\"1\" r:id=\"r1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"\(office)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"r2\" Type=\"\(office)/styles\" Target=\"styles.xml\"/></Relationships>",
            "xl/styles.xml": "<styleSheet xmlns=\"\(ns)\"><numFmts><numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd hh:mm\"/><numFmt numFmtId=\"165\" formatCode=\"[h]:mm\"/></numFmts><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"164\"/><xf numFmtId=\"165\"/></cellXfs></styleSheet>",
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(ns)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Meaning</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Value</t></is></c></row><row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t>DateAndTime</t></is></c><c r=\"B2\" s=\"1\"><v>46311.999999999999999999</v></c></row><row r=\"3\"><c r=\"A3\" t=\"inlineStr\"><is><t>Elapsed</t></is></c><c r=\"B3\" s=\"2\"><v>1.999999999999999999</v></c></row></sheetData></worksheet>"
        ]
        let source = root.appendingPathComponent("precise.xlsx")
        try ZIPFixtureBuilder.archive(entries: parts.sorted { $0.key < $1.key }.map { .init(name: $0.key, content: Data($0.value.utf8)) }).write(to: source)
        let bytes = try Data(contentsOf: source)
        let parsed = try XLSXWorkbookParser.parse(packageAt: source)
        XCTAssertEqual(parsed.sheets[0].rows[1][1].value, .number("46311.999999999999999999"))
        for rendering in [SpreadsheetRendering.markdownTable, .tabSeparated] {
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(rendering.rawValue)), options: .init(spreadsheetRendering: rendering, conversionReport: true)))
            let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for marker in ["DateAndTime", "Elapsed", "2026-10-16 23:59", "47:59"] { XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, text) }
            XCTAssertFalse(result.diagnostics.contains { $0.code == "spreadsheet.numberFormatNotPreserved" })
            XCTAssertEqual(result.sourceIdentity?.sha256, ConversionFileFingerprint.digest(bytes))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    @MainActor private func wait(_ app: AppModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while app.isConverting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(app.isConverting)
    }
}
