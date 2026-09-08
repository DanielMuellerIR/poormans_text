import Foundation
import XCTest
@testable import PoorMansTextCore

final class PresentationNotebookTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTFormats-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var png: Data { get throws { try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/WordProcessing/fixture.png")) } }
    private func entry(_ name: String, _ text: String) -> ZIPFixtureBuilder.Entry { .init(name: name, content: Data(text.utf8)) }
    private func pptxEntries() throws -> [ZIPFixtureBuilder.Entry] {
        let p = PresentationImport.presentation, a = PresentationImport.drawing, r = PresentationImport.relations
        let rel = "http://schemas.openxmlformats.org/package/2006/relationships"
        return [
            entry("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/></Types>"),
            entry("ppt/presentation.xml", "<p:presentation xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:sldIdLst><p:sldId id=\"2\" r:id=\"second\"/><p:sldId id=\"1\" r:id=\"first\"/></p:sldIdLst></p:presentation>"),
            entry("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"first\" Type=\"\(r)/slide\" Target=\"slides/slide1.xml\"/><Relationship Id=\"second\" Type=\"\(r)/slide\" Target=\"slides/slide10.xml\"/></Relationships>"),
            entry("ppt/slides/slide10.xml", """
            <p:sld xmlns:p="\(p)" xmlns:a="\(a)" xmlns:r="\(r)"><p:cSld><p:spTree><p:sp><p:txBody>
            <a:p><a:r><a:t>FIRSTTOKEN</a:t></a:r></a:p>
            <a:p><a:pPr lvl="0"><a:buAutoNum type="arabicPeriod"/></a:pPr><a:r><a:t>Parent item</a:t></a:r></a:p>
            <a:p><a:pPr lvl="1"><a:buAutoNum type="arabicPeriod"/></a:pPr><a:r><a:t>Child item</a:t></a:r></a:p>
            </p:txBody></p:sp><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>TABLETOKEN</a:t></a:r></a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>42</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl>
            <p:pic><a:blip r:embed="picture"/></p:pic></p:spTree></p:cSld></p:sld>
            """),
            entry("ppt/slides/slide1.xml", "<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>SECONDTOKEN</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"),
            entry("ppt/slides/_rels/slide10.xml.rels", "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"picture\" Type=\"\(r)/image\" Target=\"../media/picture.png\"/><Relationship Id=\"notes\" Type=\"\(r)/notesSlide\" Target=\"../notesSlides/notesSlide1.xml\"/></Relationships>"),
            entry("ppt/notesSlides/notesSlide1.xml", "<p:notes xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>NOTESTOKEN</a:t></a:r></a:p></p:txBody></p:sp><a:blip r:embed=\"picture\"/></p:spTree></p:cSld></p:notes>"),
            entry("ppt/notesSlides/_rels/notesSlide1.xml.rels", "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"picture\" Type=\"\(r)/image\" Target=\"../media/picture.png\"/></Relationships>"),
            .init(name: "ppt/media/picture.png", content: try png)
        ]
    }
    func testPowerPointVariantsKeepOrderListsTablesNotesAndImageBytes() throws {
        for (ext, type) in [("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"), ("pptm", "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml"), ("potx", "application/vnd.openxmlformats-officedocument.presentationml.template.main+xml")] {
            var entries = try pptxEntries()
            entries[0] = entry("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(type)\"/></Types>")
            let source = root.appendingPathComponent("source.\(ext)")
            try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
            let before = try Data(contentsOf: source)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(root.appendingPathComponent(ext))))
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for token in ["FIRSTTOKEN", "SECONDTOKEN", "TABLETOKEN", "NOTESTOKEN"] { XCTAssertEqual(markdown.components(separatedBy: token).count - 1, 1, markdown) }
            XCTAssertLessThan(try XCTUnwrap(markdown.range(of: "FIRSTTOKEN")).lowerBound, try XCTUnwrap(markdown.range(of: "SECONDTOKEN")).lowerBound)
            XCTAssertTrue(markdown.contains("1. Parent item\n    1. Child item\n\n| TABLETOKEN | 42 |"), markdown)
            XCTAssertTrue(markdown.contains("> NOTESTOKEN"), markdown)
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: result.assets[0]), try png)
            XCTAssertEqual(try Data(contentsOf: source), before)
            try assertTableAST(result.markdownFile)
        }
    }
    private func assertTableAST(_ markdown: URL) throws {
        guard let pandoc = try? PandocTool.resolve(nil) else { return }
        let result = try ProcessRunner.run(executable: pandoc, arguments: ["-f", "gfm", "-t", "json", markdown.path], currentDirectory: root, captureStandardOutput: true, timeout: 10)
        let json = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        func contains(_ value: Any, type: String) -> Bool {
            if let dictionary = value as? [String: Any] { return dictionary["t"] as? String == type || dictionary.values.contains { contains($0, type: type) } }
            if let array = value as? [Any] { return array.contains { contains($0, type: type) } }
            return false
        }
        XCTAssertTrue(contains(json, type: "Table"))
        XCTAssertTrue(contains(json, type: "OrderedList"))
    }
    func testPowerPointAlternateContentSelectsOneRepresentation() throws {
        let a = PresentationImport.drawing, p = PresentationImport.presentation
        func shape(_ token: String) -> String { "<p:sp><p:txBody><a:p><a:r><a:t>\(token)</a:t></a:r></a:p></p:txBody></p:sp>" }
        let xml = """
        <p:sld xmlns:p="\(p)" xmlns:a="\(a)" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:a14="urn:unsupported" xmlns:alias="\(a)">
        <p:cSld><p:spTree>
        <mc:AlternateContent><mc:Choice Requires="a14">\(shape("DUPLICATE"))</mc:Choice><mc:Fallback>\(shape("ONCETOKEN"))</mc:Fallback></mc:AlternateContent>
        <mc:AlternateContent><mc:Choice Requires="alias">\(shape("SUPPORTED"))</mc:Choice><mc:Choice Requires="a">\(shape("LATER"))</mc:Choice><mc:Fallback>\(shape("FALLBACK"))</mc:Fallback></mc:AlternateContent>
        <mc:AlternateContent><mc:Choice xmlns:alias="urn:unsupported" Requires="alias">\(shape("SHADOWED"))</mc:Choice><mc:Fallback>\(shape("SHADOWFALLBACK"))</mc:Fallback></mc:AlternateContent>
        </p:spTree></p:cSld></p:sld>
        """
        var entries = try pptxEntries().filter { $0.name != "ppt/slides/slide1.xml" }
        entries.append(entry("ppt/slides/slide1.xml", xml))
        let source = root.appendingPathComponent("alternatives.pptx")
        let bytes = try ZIPFixtureBuilder.archive(entries: entries)
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for token in ["ONCETOKEN", "SUPPORTED", "SHADOWFALLBACK"] {
            XCTAssertEqual(markdown.components(separatedBy: token).count - 1, 1, markdown)
        }
        for token in ["DUPLICATE", "LATER", "SHADOWED"] { XCTAssertFalse(markdown.contains(token), markdown) }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testNotebookCompleteResourceTargetsAndTracebackLines() throws {
        let targets = ["missing.png", "<missing file.png>", "missing(1).png", #"missing\(2\).png"#, #"<missing\>file.png>"#]
        let links = targets.map { "![x](\($0))" }.joined(separator: "\n")
        let cells: [[String: Any]] = [
            ["cell_type": "markdown", "source": links + "\n`![literal](missing(1).png)`"],
            ["cell_type": "code", "source": ["FRAG", "MENT"], "outputs": [
                ["output_type": "error", "traceback": ["FIRST FRAME", "SECOND FRAME\n", "FINAL ERROR"]],
                ["output_type": "stream", "text": ["STREAM", "FRAGMENTS"]]
            ]]
        ]
        let source = root.appendingPathComponent("resources.ipynb")
        let bytes = try JSONSerialization.data(withJSONObject: ["nbformat": 4, "cells": cells])
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "#unavailable-resource").count - 1, targets.count, markdown)
        XCTAssertTrue(markdown.contains("![x](<#unavailable-resource>)"), markdown)
        XCTAssertFalse(markdown.contains(".png)\n"), markdown)
        XCTAssertTrue(markdown.contains("`![literal](missing(1).png)`"), markdown)
        XCTAssertTrue(markdown.contains("FIRST FRAME\nSECOND FRAME\nFINAL ERROR"), markdown)
        XCTAssertTrue(markdown.contains("FRAGMENT"), markdown)
        XCTAssertTrue(markdown.contains("STREAMFRAGMENTS"), markdown)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "notebook.resourceUnavailable" })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testODPNumberedNestedListsAndNotes() throws {
        let xml = """
        <office:document-content xmlns:office="\(PresentationImport.office)" xmlns:draw="\(PresentationImport.draw)" xmlns:text="\(PresentationImport.text)" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:presentation="\(PresentationImport.presentationODF)">
        <office:automatic-styles><text:list-style style:name="Numbers"><text:list-level-style-number text:level="1"/><text:list-level-style-number text:level="2"/></text:list-style></office:automatic-styles>
        <office:body><office:presentation><draw:page draw:name="LaterName"><draw:text-box><text:p>ODPFIRST</text:p><text:list text:style-name="Numbers"><text:list-item><text:p>Parent</text:p><text:list><text:list-item><text:p>Nested</text:p></text:list-item></text:list></text:list-item></text:list></draw:text-box><presentation:notes><text:p>ODPNOTES</text:p></presentation:notes></draw:page><draw:page draw:name="EarlierName"><text:p>ODPSECOND</text:p></draw:page></office:presentation></office:body></office:document-content>
        """
        let source = root.appendingPathComponent("source.odp")
        try ZIPFixtureBuilder.archive(entries: [entry("mimetype", "application/vnd.oasis.opendocument.presentation"), entry("content.xml", xml)]).write(to: source)
        let before = try Data(contentsOf: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("1. Parent\n    1. Nested"), markdown)
        XCTAssertTrue(markdown.contains("> ODPNOTES"), markdown)
        XCTAssertLessThan(try XCTUnwrap(markdown.range(of: "ODPFIRST")).lowerBound, try XCTUnwrap(markdown.range(of: "ODPSECOND")).lowerBound)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    func testNotebookPreservesCodeOutputsAttachmentsAndDoesNotExecute() throws {
        let sentinel = root.appendingPathComponent("CODE_WAS_EXECUTED")
        let code = "from pathlib import Path\nPath(\"\(sentinel.path)\").write_text(\"bad\")\nprint(\"```\")\n# Unicode äöü\n"
        let cells: [[String: Any]] = [
            ["cell_type": "markdown", "source": "MARKDOWNTOKEN ![picture](attachment:photo.png) `![literal](attachment:photo.png)`\n![missing](attachment:absent.png)\n[bad](javascript:evil)", "attachments": ["photo.png": ["image/png": try png.base64EncodedString()]]],
            ["cell_type": "code", "source": code, "outputs": [["output_type": "stream", "text": ["STREAMTOKEN\n", "```\n"]], ["output_type": "display_data", "data": ["text/plain": "RESULTTOKEN", "image/png": try png.base64EncodedString(), "text/html": "<b>not rendered</b>"]]]],
            ["cell_type": "raw", "source": "RAWTOKEN"]
        ]
        let source = root.appendingPathComponent("source.ipynb")
        try JSONSerialization.data(withJSONObject: ["nbformat": 4, "metadata": ["language_info": ["name": "python"]], "cells": cells]).write(to: source)
        let before = try Data(contentsOf: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("````python\n" + code + "````"), markdown)
        XCTAssertTrue(markdown.contains("`![literal](attachment:photo.png)`"), markdown)
        for token in ["MARKDOWNTOKEN", "STREAMTOKEN", "RESULTTOKEN", "RAWTOKEN"] { XCTAssertEqual(markdown.components(separatedBy: token).count - 1, 1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertEqual(try Data(contentsOf: result.assets[0]), try png)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "notebook.resourceUnavailable" && $0.location?.cell == "1" })
        XCTAssertTrue(result.diagnostics.contains { $0.code == "notebook.outputNotRepresented" })
    }
    func testNotebookCellCancellationPublishesNothing() throws {
        let source = root.appendingPathComponent("cancel.ipynb")
        let cells = [["cell_type": "markdown", "source": "First cell"], ["cell_type": "code", "source": "raise RuntimeError('never execute')"]]
        let bytes = try JSONSerialization.data(withJSONObject: ["nbformat": 4, "cells": cells])
        try bytes.write(to: source)
        let token = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source), progress: { progress in
            if progress.unit == .cell && progress.completed == 1 { token.cancel() }
        }, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["cancel.ipynb"])
    }

    func testCancellationAndCRCFailurePublishNothing() throws {
        let source = root.appendingPathComponent("cancel.pptx")
        let bytes = try ZIPFixtureBuilder.archive(entries: pptxEntries())
        try bytes.write(to: source)
        let token = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source), progress: { progress in
            if progress.unit == .slide && progress.completed == 1 { token.cancel() }
        }, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["cancel.pptx"])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        var entries = try pptxEntries()
        entries.append(.init(name: "ppt/media/unused.bin", content: Data([1, 2, 3]), declaredChecksum: 0))
        let corrupt = root.appendingPathComponent("corrupt.pptx")
        try ZIPFixtureBuilder.archive(entries: entries).write(to: corrupt)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: corrupt)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("corrupt-markdown").path))
    }
    func testOversizedPackageImageIsDiagnosedWithoutLosingText() throws {
        var entries = try pptxEntries()
        entries.removeAll { $0.name == "ppt/media/picture.png" }
        entries.append(.init(name: "ppt/media/picture.png", content: Data(repeating: 0, count: 16 * 1_024 * 1_024 + 1)))
        let source = root.appendingPathComponent("large.pptx")
        try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "presentation.imageUnavailable" })
        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("FIRSTTOKEN"))
    }
    func testODPExpansionBudgetsFailBeforePublishing() throws {
        let cases = [
            "<table:table><table:table-row table:number-rows-repeated=\"1000\"><table:table-cell table:number-columns-repeated=\"256\"><text:p>" + String(repeating: "x", count: 1_024) + "</text:p></table:table-cell></table:table-row></table:table>",
            "<text:p>" + String(repeating: "<text:s text:c=\"4096\"/>", count: 40_000) + "</text:p>"
        ]
        for (index, body) in cases.enumerated() {
            let source = root.appendingPathComponent("budget\(index).odp")
            try ZIPFixtureBuilder.archive(entries: [entry("mimetype", "application/vnd.oasis.opendocument.presentation"), entry("content.xml", odpDocument(body))]).write(to: source)
            let before = try Data(contentsOf: source)
            XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: source))) { error in
                XCTAssertTrue(error.localizedDescription.contains("budget"), error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("budget\(index)-markdown").path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["budget0.odp", "budget1.odp"])
    }
    func testODPLinksAndNestedTableTextAreDiagnosedOnce() throws {
        let body = """
        <text:p><text:a xlink:href="https://invalid.test/never-load">External label</text:a> <text:a xlink:href="missing-file">Local label</text:a></text:p>
        <table:table><table:table-row><table:table-cell><text:p>Outer text</text:p><table:table><table:table-row><table:table-cell><text:p>INNERUNIQUETOKEN</text:p></table:table-cell></table:table-row></table:table></table:table-cell></table:table-row></table:table>
        """
        let source = root.appendingPathComponent("nested.odp")
        try ZIPFixtureBuilder.archive(entries: [entry("mimetype", "application/vnd.oasis.opendocument.presentation"), entry("content.xml", odpDocument(body))]).write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("External label Local label"), markdown)
        XCTAssertEqual(markdown.components(separatedBy: "INNERUNIQUETOKEN").count - 1, 1)
        XCTAssertEqual(result.diagnostics.filter { $0.code == "presentation.hyperlinkFlattened" }.count, 2)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "presentation.nestedTableFlattened" && $0.location?.page == 1 })
    }
    private func odpDocument(_ body: String) -> String {
        "<office:document-content xmlns:office=\"\(PresentationImport.office)\" xmlns:draw=\"\(PresentationImport.draw)\" xmlns:text=\"\(PresentationImport.text)\" xmlns:table=\"\(PresentationImport.table)\" xmlns:xlink=\"\(PresentationImport.xlink)\"><office:body><office:presentation><draw:page>\(body)</draw:page></office:presentation></office:body></office:document-content>"
    }
    func testInspectionRejectsMissingODPContentAndReportsPowerPointMacros() throws {
        let missing = root.appendingPathComponent("missing.odp")
        try ZIPFixtureBuilder.archive(entries: [entry("mimetype", "application/vnd.oasis.opendocument.presentation")]).write(to: missing)
        XCTAssertThrowsError(try DocumentConverter().inspect(missing))
        var entries = try pptxEntries()
        entries.append(.init(name: "ppt/vbaProject.bin", content: Data([1, 2, 3])))
        let source = root.appendingPathComponent("macro.pptm")
        try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
        let codes = try DocumentConverter().inspect(source).expectedWarnings.map(\.code)
        XCTAssertTrue(codes.contains("presentation.layoutNotPreserved"))
        XCTAssertTrue(codes.contains("presentation.macrosNotPreserved"))
    }
    func testBundleAssociationsUseEachFormatsActualSystemType() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("App/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        for (ext, uti) in [("pptx", "org.openxmlformats.presentationml.presentation"), ("pptm", "org.openxmlformats.presentationml.presentation.macroenabled"), ("potx", "org.openxmlformats.presentationml.template"), ("odp", "org.oasis-open.opendocument.presentation"), ("ipynb", "org.jupyter.ipynb"), ("ods", "org.oasis-open.opendocument.spreadsheet")] {
            let type = try XCTUnwrap(types.first { ($0["CFBundleTypeExtensions"] as? [String])?.contains(ext) == true })
            XCTAssertEqual(type["LSItemContentTypes"] as? [String], [uti])
            XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Viewer")
            XCTAssertEqual(type["LSHandlerRank"] as? String, "Alternate")
        }
    }

    func testXMLRejectsEntitiesAndUnsafePackageReferences() throws {
        XCTAssertThrowsError(try ImportXML.parse(Data("<!DOCTYPE x [<!ENTITY a 'abc'><!ENTITY b '&a;&a;'>]><x>&b;</x>".utf8)))
        XCTAssertThrowsError(try ImportXML.parse(Data("<!DOCTYPE x [<!ENTITY bomb 'expanded'>]><x>&bomb;</x>".utf8)))
        for target in ["../../escape.png", "https://invalid.test/a.png", "/tmp/a.png", "..\\a.png", "%2e%2e/%2e%2e/a.png"] {
            XCTAssertThrowsError(try ImportPackagePath.resolve(target, relativeTo: "ppt/slide.xml"), target)
        }
    }
}
