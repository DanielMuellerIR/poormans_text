import Foundation
import XCTest
@testable import PoorMansTextCore

final class PresentationNotebookTests: XCTestCase {
    func testReportMapsSlidesAfterFrontmatterAndTextbundleAssetRewrites() throws {
        var entries = try pptxEntries()
        entries.append(entry("docProps/core.xml", "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Title🙂</dc:title></cp:coreProperties>"))
        let source = root.appendingPathComponent("mapped.pptx")
        let original = try ZIPFixtureBuilder.archive(entries: entries)
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source, options: ConversionOptions(frontmatter: true, outputLayout: .textbundle, conversionReport: true)))
        let data = try Data(contentsOf: result.markdownFile)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("---\n"))
        XCTAssertEqual(result.sourceMappings.compactMap { $0.source.slide }, [1, 2])
        XCTAssertEqual(result.sourceMappings.map { $0.output.file }, ["text.md", "text.md"])
        let first = try XCTUnwrap(result.sourceMappings[0].output.text(in: data))
        XCTAssertTrue(first.contains("FIRSTTOKEN"))
        XCTAssertTrue(first.contains("NOTESTOKEN"))
        XCTAssertTrue(first.contains("](assets/image1.png)"))
        XCTAssertFalse(first.contains("](images/"))
        XCTAssertTrue(result.sourceMappings[1].output.text(in: data)?.contains("SECONDTOKEN") == true)
        XCTAssertEqual(result.sourceIdentity?.sha256, ConversionFileFingerprint.digest(original))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testSelectedSlidesKeepPresentationOrderAndSourceNumbersInBothOutputLayouts() throws {
        let original = try ZIPFixtureBuilder.archive(entries: pptxEntries())
        let source = root.appendingPathComponent("selected.pptx"); try original.write(to: source)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let destination = root.appendingPathComponent(UUID().uuidString + (layout == .textbundle ? ".textbundle" : ""))
            let selection = PresentationSelection(slides: try IndexSelection("2,2"))
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(outputLayout: layout, presentationSelection: selection, conversionReport: true)))
            let data = try Data(contentsOf: result.markdownFile), text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains("## Slide 2")); XCTAssertTrue(text.contains("SECONDTOKEN"))
            for token in ["FIRSTTOKEN", "TABLETOKEN", "NOTESTOKEN", "## Slide 1"] { XCTAssertFalse(text.contains(token)) }
            XCTAssertTrue(result.assets.isEmpty)
            XCTAssertEqual(result.sourceMappings.compactMap { $0.source.slide }, [2])
            XCTAssertTrue(result.sourceMappings[0].output.text(in: data)?.contains("SECONDTOKEN") == true)
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
            XCTAssertEqual(report.options.presentationSelection, selection)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDefaultAndExplicitAllSlidesAreByteEqualAndNotesCanBeExcluded() throws {
        let source = root.appendingPathComponent("notes.pptx")
        let original = try ZIPFixtureBuilder.archive(entries: pptxEntries()); try original.write(to: source)
        var outputs = [Data]()
        for selection in [PresentationSelection?.none, PresentationSelection(slides: try IndexSelection("2,1,2"))] {
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(UUID().uuidString)), options: .init(presentationSelection: selection)))
            outputs.append(try Data(contentsOf: result.markdownFile))
            XCTAssertEqual(result.assets.count, 1)
        }
        XCTAssertEqual(outputs[0], outputs[1])
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("without-notes")), options: .init(presentationSelection: .init(includeNotes: false))))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertFalse(text.contains("NOTESTOKEN")); XCTAssertFalse(text.contains("### Notes"))
        XCTAssertTrue(text.contains("FIRSTTOKEN")); XCTAssertTrue(text.contains("TABLETOKEN"))
        XCTAssertEqual(text.components(separatedBy: "![Slide image]").count - 1, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), try png)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExcludedBrokenSlidesAndNotesDoNotCreateLossDiagnostics() throws {
        var entries = try pptxEntries(); entries.removeAll { $0.name == "ppt/slides/slide10.xml" }
        let source = root.appendingPathComponent("missing-slide.pptx"); try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("selected-good")), options: .init(presentationSelection: .init(slides: IndexSelection("2")))))
        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertFalse(result.diagnostics.contains { $0.kind == .contentLoss })
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("all-broken")))))
        entries = try pptxEntries(); entries.removeAll { $0.name == "ppt/notesSlides/notesSlide1.xml" }
        let notes = root.appendingPathComponent("missing-notes.pptx"); try ZIPFixtureBuilder.archive(entries: entries).write(to: notes)
        for include in [false, true] {
            let result = try DocumentConverter().convert(.init(inputURL: notes, destination: .directory(root.appendingPathComponent(UUID().uuidString)), options: .init(presentationSelection: .init(slides: IndexSelection("1"), includeNotes: include))))
            XCTAssertEqual(result.diagnostics.contains { $0.code == "presentation.notesUnavailable" }, include)
            if include { XCTAssertTrue(result.diagnostics.contains { $0.code == "presentation.notesUnavailable" && $0.location?.slide == 1 }) }
        }
    }

    func testPresentationOverviewIsBoundedVerifiedAndHasNoOutputOrAssetSideEffects() throws {
        var entries = try pptxEntries()
        entries = entries.map { item in
            guard item.name == "ppt/slides/slide10.xml" else { return item }
            return entry(item.name, String(decoding: item.content, as: UTF8.self).replacingOccurrences(of: "FIRSTTOKEN", with: String(repeating: "Long🙂", count: 100)))
        }
        let source = root.appendingPathComponent("overview.pptx"); let original = try ZIPFixtureBuilder.archive(entries: entries); try original.write(to: source)
        let summary = try DocumentConverter().inspectPresentationContents(source, maximumSlides: 1)
        XCTAssertEqual(summary.slideCount, 2); XCTAssertEqual(summary.slides.map(\.number), [1]); XCTAssertTrue(summary.slidesTruncated)
        XCTAssertTrue(summary.slides[0].hasNotes); XCTAssertLessThanOrEqual(try XCTUnwrap(summary.slides[0].title).utf8.count, 256)
        XCTAssertFalse(summary.slides[0].title!.contains("�"))
        XCTAssertTrue(try summary.sourceIdentity.matchesFile(at: source))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["overview.pptx"])
        for limit in [0, 501] { XCTAssertThrowsError(try DocumentConverter().inspectPresentationContents(source, maximumSlides: limit)) }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testODPSelectedNotesRetainTextTableAndImageAndCanBeExcluded() throws {
        let body = """
        <text:p>ODPBODY1</text:p><presentation:notes xmlns:presentation="\(PresentationImport.presentationODF)">
        <text:p>ODPNOTES</text:p><table:table><table:table-row><table:table-cell><text:p>NOTETABLE</text:p></table:table-cell></table:table-row></table:table>
        <draw:frame><draw:image xlink:href="Pictures/note.png"/></draw:frame></presentation:notes>
        """
        let xml = odpDocument(body).replacingOccurrences(of: "</draw:page>", with: "</draw:page><draw:page><text:p>ODPBODY2</text:p></draw:page>")
        let source = root.appendingPathComponent("notes.odp")
        let original = try ZIPFixtureBuilder.archive(entries: [entry("mimetype", "application/vnd.oasis.opendocument.presentation"), entry("content.xml", xml), .init(name: "Pictures/note.png", content: png)])
        try original.write(to: source)
        let summary = try DocumentConverter().inspectPresentationContents(source)
        XCTAssertEqual(summary.slides.map(\.title), ["ODPBODY1", "ODPBODY2"]); XCTAssertEqual(summary.slides.map(\.hasNotes), [true, false])
        for include in [false, true] {
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(UUID().uuidString)), options: .init(presentationSelection: .init(slides: IndexSelection("1"), includeNotes: include), conversionReport: true)))
            let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertTrue(text.contains("ODPBODY1")); XCTAssertFalse(text.contains("ODPBODY2"))
            XCTAssertEqual(text.contains("ODPNOTES"), include); XCTAssertEqual(text.contains("NOTETABLE"), include)
            XCTAssertEqual(result.assets.count, include ? 1 : 0)
            if include { XCTAssertEqual(try Data(contentsOf: result.assets[0]), try png) }
            XCTAssertEqual(result.sourceMappings.compactMap { $0.source.slide }, [1])
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPresentationSelectionCancellationWrongInputAndInvalidRangesNeverPublish() throws {
        let source = root.appendingPathComponent("cancel.pptx"); try ZIPFixtureBuilder.archive(entries: pptxEntries()).write(to: source)
        let destination = root.appendingPathComponent("never")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(presentationSelection: .init(slides: IndexSelection("3"))))))
        let token = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(presentationSelection: .init(slides: IndexSelection("2")))), progress: { event in if event.unit == .slide { token.cancel() } }, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try DocumentConverter().inspectPresentationContents(source, cancellation: token))
        let csv = root.appendingPathComponent("values.csv"); try Data("Name,Value\nMarker,1\n".utf8).write(to: csv)
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: csv, destination: .directory(destination), options: .init(presentationSelection: .init(includeNotes: false)))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
    }

    func testPresentationSelectionStillVerifiesExcludedAssetBytes() throws {
        var entries = try pptxEntries()
        let index = try XCTUnwrap(entries.firstIndex { $0.name == "ppt/media/picture.png" }); entries[index].declaredChecksum = 0
        let source = root.appendingPathComponent("corrupt.pptx"); try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
        let destination = root.appendingPathComponent("never")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(presentationSelection: .init(slides: IndexSelection("2")), conversionReport: true))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSelectedSlideProgressCountsSelectedWorkAndKeepsPhysicalNumber() throws {
        let source = root.appendingPathComponent("progress.pptx"); try ZIPFixtureBuilder.archive(entries: pptxEntries()).write(to: source)
        let progress = SelectedSlideProgress()
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("progress-result")), options: .init(presentationSelection: .init(slides: IndexSelection("2")), sourceMapping: true)), progress: { if $0.unit == .slide { progress.append($0) } })
        XCTAssertEqual(progress.snapshot.map(\.completed), [0, 1]); XCTAssertEqual(progress.snapshot.map(\.total), [1, 1])
        XCTAssertEqual(result.sourceMappings.map { $0.source.slide }, [2])
    }

    func testSlideSelectionDoesNotBypassSourceSlideCountLimit() throws {
        var entries = try pptxEntries()
        entries = entries.map { item in
            guard item.name == "ppt/presentation.xml" else { return item }
            let ids = String(repeating: "<p:sldId id=\"1\" r:id=\"first\"/>", count: 1_001)
            return entry(item.name, "<p:presentation xmlns:p=\"\(PresentationImport.presentation)\" xmlns:r=\"\(PresentationImport.relations)\"><p:sldIdLst>\(ids)</p:sldIdLst></p:presentation>")
        }
        let source = root.appendingPathComponent("too-many.pptx"); try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
        let destination = root.appendingPathComponent("never")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(presentationSelection: .init(slides: IndexSelection("1"))))))
        XCTAssertThrowsError(try DocumentConverter().inspectPresentationContents(source, maximumSlides: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private final class SelectedSlideProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [ConversionProgress]()
        func append(_ value: ConversionProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var snapshot: [ConversionProgress] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTFormats-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var png: Data { get throws { try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/WordProcessing/fixture.png")) } }
    private func entry(_ name: String, _ text: String) -> ZIPFixtureBuilder.Entry { .init(name: name, content: Data(text.utf8)) }
    func testPowerPointTableHyperlinkReportsLostTargetAndKeepsItsText() throws {
        var entries = try pptxEntries()
        let index = try XCTUnwrap(entries.firstIndex { $0.name == "ppt/slides/slide10.xml" })
        let xml = String(decoding: entries[index].content, as: UTF8.self)
            .replacingOccurrences(of: "<a:t>TABLETOKEN</a:t>", with: "<a:rPr><a:hlinkClick r:id=\"link\"/></a:rPr><a:t>TABLETOKEN</a:t>")
        entries[index] = entry(entries[index].name, xml)
        let source = root.appendingPathComponent("table-link.pptx")
        let bytes = try ZIPFixtureBuilder.archive(entries: entries)
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "presentation.linkUnavailable" })
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "TABLETOKEN").count - 1, 1)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
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
    func testSlideParagraphAndNoteDiagnosticsUseSourcePositions() throws {
        var entries = try pptxEntries()
        for (part, marker) in [("ppt/slides/slide10.xml", "FIRSTTOKEN"), ("ppt/notesSlides/notesSlide1.xml", "NOTESTOKEN")] {
            let index = try XCTUnwrap(entries.firstIndex { $0.name == part })
            let xml = String(decoding: entries[index].content, as: UTF8.self)
                .replacingOccurrences(of: "<a:t>\(marker)</a:t>", with: "<a:rPr><a:hlinkClick r:id=\"link\"/></a:rPr><a:t>\(marker)</a:t>")
            entries[index] = entry(part, xml)
        }
        let source = root.appendingPathComponent("positions.pptx")
        let original = try ZIPFixtureBuilder.archive(entries: entries)
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let links = result.diagnostics.filter { $0.code == "presentation.linkUnavailable" }
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.compactMap { $0.location?.slide }, [1, 1])
        XCTAssertEqual(links.compactMap { $0.location?.paragraph }, [1, 1])
        XCTAssertNil(links.first?.location?.note)
        XCTAssertEqual(links.last?.location?.note, "ppt/notesSlides/notesSlide1.xml")
        XCTAssertTrue(links.allSatisfy { $0.kind == .contentLoss })
        let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for marker in ["FIRSTTOKEN", "TABLETOKEN", "SECONDTOKEN", "NOTESTOKEN"] {
            XCTAssertEqual(output.components(separatedBy: marker).count - 1, 1)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
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

    func testNotebookResourceBudgetIgnoresFencedCodeExamples() throws {
        let examples = (0...4_096).map { "![example](missing-\($0).png)" }.joined(separator: "\n")
        let source = root.appendingPathComponent("code-examples.ipynb")
        let cell = "```markdown\n\(examples)\n```\n![real](missing.png)"
        let bytes = try JSONSerialization.data(
            withJSONObject: ["nbformat": 4, "cells": [["cell_type": "markdown", "source": cell]]]
        )
        try bytes.write(to: source)

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "#unavailable-resource").count - 1, 1)
        XCTAssertTrue(markdown.contains("![example](missing-4096.png)"), markdown)
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
    func testCorruptPixelPayloadIsDiagnosedInPresentationAndNotebook() throws {
        let corrupt = Data(try png.prefix(33))
        var entries = try pptxEntries().filter { $0.name != "ppt/media/picture.png" }
        entries.append(.init(name: "ppt/media/picture.png", content: corrupt))
        let presentation = root.appendingPathComponent("bad-pixels.pptx")
        try ZIPFixtureBuilder.archive(entries: entries).write(to: presentation)
        let notebook = root.appendingPathComponent("bad-pixels-notebook.ipynb")
        try JSONSerialization.data(withJSONObject: ["nbformat": 4, "cells": [
            ["cell_type": "code", "source": "KEEPTOKEN", "outputs": [
                ["output_type": "display_data", "data": ["image/png": corrupt.base64EncodedString(), "text/plain": "OUTPUTTOKEN"]]
            ]]
        ]]).write(to: notebook)
        for (source, code, token) in [(presentation, "presentation.imageUnavailable", "FIRSTTOKEN"),
                                      (notebook, "notebook.imageUnavailable", "KEEPTOKEN")] {
            let before = try Data(contentsOf: source)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
            XCTAssertTrue(result.assets.isEmpty)
            XCTAssertTrue(result.diagnostics.contains { $0.code == code }, "\(result.diagnostics)")
            XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains(token))
            XCTAssertEqual(try Data(contentsOf: source), before)
        }
    }

    func testODPTableHeadingAndNestedTextBoxAppearExactlyOnce() throws {
        let body = """
        <table:table><table:table-row><table:table-cell><text:h>HEADINGTOKEN</text:h>
        <text:p>OUTERTOKEN<draw:frame><draw:text-box><text:p>INNERTOKEN</text:p></draw:text-box></draw:frame></text:p>
        </table:table-cell></table:table-row></table:table>
        """
        let source = root.appendingPathComponent("table-text.odp")
        let before = try ZIPFixtureBuilder.archive(entries: [entry("mimetype", "application/vnd.oasis.opendocument.presentation"), entry("content.xml", odpDocument(body))])
        try before.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for token in ["HEADINGTOKEN", "OUTERTOKEN", "INNERTOKEN"] { XCTAssertEqual(text.components(separatedBy: token).count - 1, 1, text) }
        XCTAssertEqual(try Data(contentsOf: source), before)
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
        XCTAssertTrue(markdown.contains("[External label](https://invalid.test/never-load) Local label"), markdown)
        XCTAssertEqual(markdown.components(separatedBy: "INNERUNIQUETOKEN").count - 1, 1)
        XCTAssertEqual(result.diagnostics.filter { $0.code == "presentation.linkUnsafe" }.count, 1)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "presentation.nestedTableFlattened" && $0.location?.page == 1 })
    }
    /// Ein Bild im Absatz (`text:p` > `draw:frame` > `draw:image`) fiel ohne
    /// Diagnose weg, weil der Leser den Absatz mit seinem Text beantwortete.
    func testODPImageInsideAParagraphIsKept() throws {
        let xml = odpDocument("<text:p>Vorher<draw:frame><draw:image xlink:href=\"Pictures/p.png\"/></draw:frame></text:p><text:p><draw:frame><draw:image xlink:href=\"Pictures/p.png\"/></draw:frame></text:p>")
        let source = root.appendingPathComponent("inline-image.odp")
        try ZIPFixtureBuilder.archive(entries: [
            entry("mimetype", "application/vnd.oasis.opendocument.presentation"), entry("content.xml", xml),
            .init(name: "Pictures/p.png", content: try png),
        ]).write(to: source)

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(result.assets.count, 1)
        XCTAssertTrue(markdown.contains("Vorher\n\n![Slide image](images/image1.png)"), markdown)
        XCTAssertEqual(markdown.components(separatedBy: "![Slide image](images/image1.png)").count - 1, 2, markdown)
        XCTAssertFalse(result.diagnostics.contains { $0.code == "presentation.imageUnavailable" })
    }

    func testODPTableCellImagesAndTextSurviveRealConversion() throws {
        let body = """
        <table:table><table:table-row table:number-rows-repeated="2"><table:table-cell table:number-columns-repeated="3"><text:p>CELLTOKEN<draw:frame><draw:image xlink:href="Pictures/p.png"/></draw:frame></text:p></table:table-cell></table:table-row></table:table>
        """
        let image = try png
        let original = try ZIPFixtureBuilder.archive(entries: [
            entry("mimetype", "application/vnd.oasis.opendocument.presentation"), entry("content.xml", odpDocument(body)),
            .init(name: "Pictures/p.png", content: image)
        ])
        let source = root.appendingPathComponent("table-image.odp")
        try original.write(to: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
        XCTAssertEqual(result.assets.count, 1)
        if let asset = result.assets.first { XCTAssertEqual(try Data(contentsOf: asset), image) }
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.components(separatedBy: "CELLTOKEN").count - 1, 6, markdown)
        XCTAssertEqual(markdown.components(separatedBy: "![Slide image]").count - 1, 6, markdown)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    /// Dasselbe Bild mit drei Verweisen wird einmal aus dem Paket gelesen;
    /// vorher holte der Leser den Eintrag je `a:blip` erneut und hashte ihn neu.
    func testAnImageReferencedSeveralTimesIsReadFromThePackageOnce() throws {
        var entries = try pptxEntries()
        let p = PresentationImport.presentation, a = PresentationImport.drawing, r = PresentationImport.relations
        entries.removeAll { $0.name == "ppt/slides/slide1.xml" }
        entries.append(entry("ppt/slides/slide1.xml", "<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld><p:spTree><p:pic><a:blip r:embed=\"picture\"/></p:pic><p:pic><a:blip r:embed=\"picture\"/></p:pic><p:pic><a:blip r:embed=\"picture\"/></p:pic></p:spTree></p:cSld></p:sld>"))
        entries.append(entry("ppt/slides/_rels/slide1.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"picture\" Type=\"\(r)/image\" Target=\"../media/picture.png\"/></Relationships>"))
        let source = root.appendingPathComponent("repeated.pptx")
        try ZIPFixtureBuilder.archive(entries: entries).write(to: source)
        let output = root.appendingPathComponent("repeated-output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let reader = CountingReader(base: try ZIPArchiveInspector.inspectionSnapshot(at: source))
        let importer = PresentationImport(reader: reader, output: output)
        let markdown = try importer.convert(format: .pptx, title: "Wiederholt")

        XCTAssertEqual(reader.reads["ppt/media/picture.png"], 1)
        XCTAssertEqual(importer.media.paths, ["images/image1.png"])
        XCTAssertEqual(markdown.components(separatedBy: "![Slide image](images/image1.png)").count - 1, 5, markdown)
    }

    /// Zählt, wie oft jeder Paketeintrag gelesen wird.
    private final class CountingReader: ZIPPackageReading {
        let base: any ZIPPackageReading
        var reads: [String: Int] = [:]
        init(base: any ZIPPackageReading) { self.base = base }
        var entryNames: Set<String> { base.entryNames }
        func data(named name: String) throws -> Data {
            reads[name, default: 0] += 1
            return try base.data(named: name)
        }
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
    // MARK: - Review-Funde 2026-09-10

    private func notebook(_ cells: [[String: Any]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PMTNotebook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Buch.ipynb")
        let json: [String: Any] = ["cells": cells, "metadata": [:], "nbformat": 4, "nbformat_minor": 5]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    private static let tinyPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg=="

    /// Ein Verweis der QUELLE auf einen von uns vergebenen Asset-Namen zeigte
    /// still auf den Anhang einer ANDEREN Zelle — je nach Zellenreihenfolge
    /// einmal so und einmal als fehlend gemeldet.
    func testAReferenceToAnotherCellsAssetNameIsReportedInEitherCellOrder() throws {
        let withAttachment: [String: Any] = [
            "cell_type": "markdown", "metadata": [:],
            "source": ["![a](attachment:x.png)\n"],
            "attachments": ["x.png": ["image/png": Self.tinyPNGBase64]],
        ]
        let borrowing: [String: Any] = [
            "cell_type": "markdown", "metadata": [:],
            "source": ["![b](images/image1.png)\n"],
        ]

        for cells in [[withAttachment, borrowing], [borrowing, withAttachment]] {
            let url = try notebook(cells)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: url))
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

            XCTAssertTrue(markdown.contains("![b](#unavailable-resource)"), markdown)
            XCTAssertTrue(markdown.contains("![a](images/image1.png)"), markdown)
            XCTAssertTrue(result.diagnostics.contains { $0.code == "notebook.resourceUnavailable" })
        }
    }

    /// Alle Anhänge einer Zelle werden ersetzt, auch viele. Die Ersetzung läuft
    /// seit dem 2026-09-10 in EINEM Durchlauf statt einmal je Anhang; die
    /// Beschleunigung selbst ist gemessen (20 000 Anhänge: über zehn Minuten
    /// und nicht abbrechbar gegen 1,6 Sekunden) und steht bewusst nicht als
    /// Zeitzusicherung hier — ein Zeitvergleich im Test wäre auf einer
    /// ausgelasteten Maschine unzuverlässig und träfe die quadratische Kurve
    /// erst bei einer Größe, die die Suite spürbar verlangsamt.
    func testEveryAttachmentOfACellIsRewritten() throws {
        let count = 200
        var attachments = [String: Any]()
        var source = [String]()
        for index in 0..<count {
            attachments["a\(index).png"] = ["image/png": Self.tinyPNGBase64]
            source.append("![\(index)](attachment:a\(index).png)\n")
        }
        let url = try notebook([[
            "cell_type": "markdown", "metadata": [:], "source": source, "attachments": attachments,
        ]])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: url))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertFalse(markdown.contains("attachment:"), "kein Anhangsverweis bleibt stehen")
        XCTAssertFalse(markdown.contains("#unavailable-resource"), markdown)
        XCTAssertEqual(result.assets.count, 1, "gleiche Bytes ergeben eine Datei")
    }

}
