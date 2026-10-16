import Foundation
import XCTest
@testable import PoorMansTextCore

final class ConversionReportTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTReport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCellRangesSurviveUnicodeFrontmatterAndBothOutputLayoutsAndRenderings() throws {
        let source = root.appendingPathComponent("Grüße🙂.xlsx")
        let xml = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
          <row r="1"><c r="A1" t="inlineStr"><is><t>Meaning</t></is></c><c r="B1" t="inlineStr"><is><t>Value</t></is></c></row>
          <row r="2"><c r="A2" t="inlineStr"><is><t>Gruß🙂éMarker</t></is></c><c r="B2"><v>42</v></c></row>
        </sheetData></worksheet>
        """
        let core = "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Title🙂</dc:title></cp:coreProperties>"
        let original = try ZIPFixtureBuilder.xlsxPackage(firstSheetXML: xml, secondSheetXML: xml, extraEntries: [.init(name: "docProps/core.xml", content: Data(core.utf8))])
        try original.write(to: source)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            for rendering in [SpreadsheetRendering.markdownTable, .tabSeparated] {
                let folder = root.appendingPathComponent("\(layout.rawValue)-\(rendering.rawValue)" + (layout == .textbundle ? ".textbundle" : ""))
                let result = try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(folder), options: ConversionOptions(spreadsheetRendering: rendering, frontmatter: true, outputLayout: layout, conversionReport: true)))
                let data = try Data(contentsOf: result.markdownFile)
                XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("---\n"))
                let markers = result.sourceMappings.filter { $0.source.cell == "A2" }
                XCTAssertEqual(markers.count, 2)
                XCTAssertTrue(markers.allSatisfy { $0.output.text(in: data) == "Gruß🙂éMarker" })
                XCTAssertTrue(markers.allSatisfy { $0.output.utf8Offset > 30 })
                let reportData = try Data(contentsOf: XCTUnwrap(result.reportFile))
                let report = try JSONDecoder().decode(ConversionReport.self, from: reportData)
                XCTAssertEqual(report.schemaVersion, 1)
                XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
                XCTAssertEqual(report.source.byteCount, original.count)
                XCTAssertEqual(report.sourceMappings, result.sourceMappings)
                XCTAssertTrue(try XCTUnwrap(result.sourceIdentity).matchesFile(at: source))
                XCTAssertFalse(String(decoding: reportData, as: UTF8.self).contains(root.path))
                for file in report.outputs {
                    XCTAssertTrue(file.matches(try Data(contentsOf: result.outputDirectory.appendingPathComponent(file.path))))
                    XCTAssertFalse(file.path.hasPrefix("/"))
                }
                XCTAssertFalse(report.outputs.contains { $0.path == "conversion-report.json" })
                XCTAssertEqual(try Data(contentsOf: source), original)
            }
        }
    }

    func testSourceMappingAloneKeepsStandardMarkdownAndWritesNoReport() throws {
        let source = root.appendingPathComponent("values.csv")
        let original = Data("Name,Value\nUnicode🙂Marker,42\n".utf8)
        try original.write(to: source)
        let plain = try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(root.appendingPathComponent("plain"))))
        let mapped = try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(root.appendingPathComponent("mapped")), options: ConversionOptions(sourceMapping: true)))
        XCTAssertNil(plain.sourceIdentity)
        XCTAssertTrue(plain.sourceMappings.isEmpty)
        XCTAssertNil(mapped.reportFile)
        XCTAssertEqual(try Data(contentsOf: plain.markdownFile), try Data(contentsOf: mapped.markdownFile))
        XCTAssertFalse(mapped.sourceMappings.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mapped.outputDirectory.path), ["values.md"])
        try Data("changed".utf8).write(to: source)
        XCTAssertFalse(try XCTUnwrap(mapped.sourceIdentity).matchesFile(at: source))
        let output = try XCTUnwrap(mapped.outputFiles.first)
        XCTAssertFalse(output.matches(Data("changed output".utf8)))
    }

    func testCancellationAndCollisionPublishNoPartialReport() throws {
        let source = root.appendingPathComponent("values.csv")
        let original = Data("Name,Value\nMarker,42\n".utf8)
        try original.write(to: source)
        let output = root.appendingPathComponent("result")
        let token = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(output), options: ConversionOptions(conversionReport: true)), progress: { progress in
            if progress.phase == .publishing { token.cancel() }
        }, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["values.csv"])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let existing = output.appendingPathComponent("conversion-report.json")
        try Data("existing".utf8).write(to: existing)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(output), options: ConversionOptions(conversionReport: true))))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExistingStagedReportIsNotOverwrittenAndKeepsFilesystemFailure() throws {
        let source = root.appendingPathComponent("source.test")
        try Data("source".utf8).write(to: source)
        let output = root.appendingPathComponent("result")
        let converter = DocumentConverter(adapters: [ReportTestAdapter(existingReport: true)])
        XCTAssertThrowsError(try converter.convert(ConversionRequest(inputURL: source, destination: .directory(output), options: ConversionOptions(conversionReport: true)))) { error in
            guard case ConversionError.fileSystemFailure = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testChangedSourceBetweenReadsCannotReceiveAFalseIdentity() throws {
        let source = root.appendingPathComponent("source.test")
        try Data("first".utf8).write(to: source)
        let output = root.appendingPathComponent("result")
        let converter = DocumentConverter(adapters: [ReportTestAdapter(readTwice: true)])
        XCTAssertThrowsError(try converter.convert(ConversionRequest(inputURL: source, destination: .directory(output), options: ConversionOptions(conversionReport: true)), progress: { progress in
            if progress.unit == .file, progress.completed == 1 { try? Data("second".utf8).write(to: source, options: .atomic) }
        })) { error in
            guard case ConversionError.invalidInput = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testReportRedactsKnownPrivatePathsWhileRetainingOriginalDiagnostics() throws {
        let source = root.appendingPathComponent("source.test")
        try Data("source".utf8).write(to: source)
        let result = try DocumentConverter(adapters: [ReportTestAdapter()]).convert(ConversionRequest(inputURL: source, options: ConversionOptions(conversionReport: true)))
        XCTAssertTrue(result.diagnostics.first?.message.contains(root.path) == true)
        let report = try Data(contentsOf: XCTUnwrap(result.reportFile))
        XCTAssertFalse(String(decoding: report, as: UTF8.self).contains(root.path))
        XCTAssertTrue(String(decoding: report, as: UTF8.self).contains("[source]"))
    }

    func testByteRangesRejectOverflowAndSplitUnicodeIncludingEmptyAnchors() {
        let data = Data("a🙂b".utf8)
        XCTAssertEqual(ConversionTextRange(file: "text.md", utf8Offset: 1, utf8Length: 4).text(in: data), "🙂")
        for range in [(2, 1), (2, 0), (Int.max, 1), (0, Int.max), (-1, 1)] {
            XCTAssertNil(ConversionTextRange(file: "text.md", utf8Offset: range.0, utf8Length: range.1).text(in: data))
        }
    }

    func testPortableDiagnosticFieldsAreBoundedWithoutInventingShortenedIdentifiers() {
        let warning = ConversionWarning(code: "test.detail", message: String(repeating: "🙂", count: 5000), location: ConversionLocation(sheet: String(repeating: "x", count: 5000), cell: "B3"))
        let portable = ConversionPostprocessor.portableDiagnostics([warning], paths: [])
        XCTAssertNil(portable[0].location?.sheet)
        XCTAssertEqual(portable[0].location?.cell, "B3")
        XCTAssertLessThanOrEqual(portable[0].message.utf8.count, 16_387)
        XCTAssertEqual(portable.last?.code, "report.detailsLimited")
        XCTAssertTrue(portable.last?.message.contains("2 oversized") == true)
        XCTAssertEqual(warning.location?.sheet?.count, 5000)
    }

    func testObservedLinkEditsRemapReferenceDefinitionsAndProtectCode() throws {
        let original = "🙂 Prefix\r\n\r\n[reference]:\r\n  <images/a.png>\r\n  \"Title\"\r\n\r\n[Visible](images/a.png)\r\n\r\n`[Literal](images/a.png)`\r\n\r\n> ```text\r\n> [Code](images/a.png)\r\n> ```\r\n\r\n[After](images/a.png)\r\n"
        let fragments = ["<images/a.png>", "[Visible](images/a.png)", "`[Literal](images/a.png)`", "[Code](images/a.png)", "[After](images/a.png)"]
        let recording = ConversionRecording()
        for (index, fragment) in fragments.enumerated() {
            let range = try XCTUnwrap(original.range(of: fragment))
            recording.record(ConversionLocation(cell: String(index)), offset: original.utf8.distance(from: original.startIndex, to: range.lowerBound), length: fragment.utf8.count)
        }
        let target = try XCTUnwrap(original.range(of: "images/a.png"))
        recording.record(ConversionLocation(cell: "Inside"), offset: original.utf8.distance(from: original.startIndex, to: target.lowerBound) + 2, length: 0)
        var edits: [ConversionTextEdit] = []
        let rewritten = try MarkdownLinkTargetRewriter.replacing(in: original, mapping: ["images/a.png": "assets/picture.png"], checking: {}, observing: { edits.append($0) })
        XCTAssertEqual(edits.count, 3)
        recording.apply(edits)
        let data = Data(rewritten.utf8)
        let maps = try recording.mappings(file: "text.md", markdown: data)
        XCTAssertEqual(recording.omittedMappingCount, 1)
        XCTAssertEqual(maps.map { $0.output.text(in: data) }, ["<assets/picture.png>", "[Visible](assets/picture.png)", "`[Literal](images/a.png)`", "[Code](images/a.png)", "[After](assets/picture.png)"])
    }

    func testSourceMappingLimitDoesNotTruncateRepeatedDocumentRows() throws {
        let source = root.appendingPathComponent("repeated.ods")
        let xml = """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:spreadsheet><table:table table:name="Values"><table:table-row table:number-rows-repeated="100001"><table:table-cell office:value-type="string"><text:p>Marker</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body>
        </office:document-content>
        """
        let original = try ZIPFixtureBuilder.odsPackage(contentXML: xml)
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source, options: ConversionOptions(sourceMapping: true)))
        XCTAssertEqual(result.sourceMappings.count, 100_000)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "sourceMap.limited" && $0.omittedCount == 1 })
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "| Marker |").count - 1, 100_001)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}

private struct ReportTestAdapter: DocumentConversionAdapter {
    var existingReport = false
    var readTwice = false
    let supportedFormatDescriptors = [SupportedFormat(format: .csv, fileExtensions: ["test"], containerKind: .file, requiredTools: [])]
    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        .match(AdapterInputInspection(format: .csv, priority: 999, expectedWarnings: []))
    }
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        _ = try VerifiedFileStaging.contents(of: context.resolvedInputURL, maximumBytes: 1024, describedAs: "test source")
        if readTwice {
            try ConversionExecution.report(unit: .file, completed: 1, total: 2)
            _ = try VerifiedFileStaging.contents(of: context.resolvedInputURL, maximumBytes: 1024, describedAs: "test source")
        }
        if existingReport { try Data("existing".utf8).write(to: context.stagedOutputDirectory.appendingPathComponent("conversion-report.json")) }
        let path = try context.writeMarkdown("Marker\n")
        return StagedConversionResult(markdownRelativePath: path, assetRelativePaths: [], warnings: [ConversionWarning(code: "test.detail", message: "Source \(context.resolvedInputURL.path), staging \(context.workDirectory.path)")])
    }
}
