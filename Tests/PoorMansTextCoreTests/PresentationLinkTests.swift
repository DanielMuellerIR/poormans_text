import Foundation
import XCTest
import Markdown
@testable import PoorMansTextCore

final class PresentationLinkTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTPresentationLinks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func destinations(_ text: String) -> [String] {
        var result: [String] = []
        func visit(_ node: any Markup) {
            if let link = node as? Link, let target = link.destination { result.append(target) }
            for child in node.children { visit(child) }
        }
        visit(Document(parsing: text)); return result
    }
    func testRealPowerPointVariantsAndODPPreserveEveryLinkAndAsset() throws {
        var receipts: [[String: Any]] = []
        for ext in ["pptx", "pptm", "potx", "odp"] {
            let source = root.appendingPathComponent("links.\(ext)")
            let bytes = try PresentationLinkFixture.data(ext: ext)
            try bytes.write(to: source)
            let output = root.appendingPathComponent(ext)
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(output), options: .init(conversionReport: true)))
            let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            let expected = [PresentationLinkFixture.webEncoded, "mailto:review@example.com", "#pmt-slide-2", PresentationLinkFixture.webEncoded, "mailto:review@example.com", PresentationLinkFixture.webEncoded, "#pmt-slide-1"]
            XCTAssertEqual(destinations(text), expected, text)
            for token in ["BODYONE", "WEB_LABEL", "MAIL_LABEL", "JUMP_LABEL", "CELL_ONE", "CELL_TWO", "NOTE_WEB", "NOTE_JUMP", "BODYTWO"] {
                XCTAssertEqual(text.replacingOccurrences(of: "\\_", with: "_").components(separatedBy: token).count - 1, 1, text)
            }
            for number in 1...2 { XCTAssertEqual(text.components(separatedBy: "<a id=\"pmt-slide-\(number)\"></a>").count - 1, 1) }
            XCTAssertTrue(text.contains("\\[x\\]")); XCTAssertTrue(text.contains("\\|")); XCTAssertTrue(text.contains("🙂"))
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), try PresentationLinkFixture.image)
            XCTAssertFalse(result.diagnostics.contains { $0.code.hasPrefix("presentation.link") }, "\(result.diagnostics)")
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(result.sourceMappings.compactMap { $0.source.slide }, [1, 2])
            let data = try Data(contentsOf: result.markdownFile)
            for mapping in result.sourceMappings { XCTAssertNotNil(mapping.output.text(in: data)) }
            receipts.append(["format": ext, "links": destinations(text), "sourceSHA256": ConversionFileFingerprint.digest(bytes), "assetSHA256": ConversionFileFingerprint.digest(try PresentationLinkFixture.image)])
            if let path = ProcessInfo.processInfo.environment["PMT_PRESENTATION_LINK_DIR"] {
                let export = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: export.appendingPathComponent(source.lastPathComponent))
                try FileManager.default.copyItem(at: output, to: export.appendingPathComponent(ext))
            }
        }
        if let path = ProcessInfo.processInfo.environment["PMT_PRESENTATION_LINK_DIR"] {
            try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path).appendingPathComponent("matrix.json"))
        }
    }
    func testSelectionAndNotesNeverLeaveDeadSlideLinks() throws {
        for ext in ["pptx", "odp"] {
            let source = root.appendingPathComponent("selected.\(ext)"); let bytes = try PresentationLinkFixture.data(ext: ext); try bytes.write(to: source)
            for notes in [false, true] {
                let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(UUID().uuidString + ".textbundle")), options: .init(frontmatter: true, outputLayout: .textbundle, presentationSelection: .init(slides: IndexSelection("1"), includeNotes: notes), conversionReport: true)))
                let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
                XCTAssertEqual(destinations(text).count, notes ? 6 : 4)
                XCTAssertFalse(destinations(text).contains("#pmt-slide-2")); XCTAssertFalse(text.contains("id=\"pmt-slide-2\""))
                XCTAssertEqual(result.diagnostics.filter { $0.code == "presentation.linkExcluded" }.count, 1)
                XCTAssertEqual(result.diagnostics.first { $0.code == "presentation.linkExcluded" }?.location?.slide, 1)
                XCTAssertTrue(text.contains("JUMP\\_LABEL")); XCTAssertEqual(text.contains("NOTE\\_WEB"), notes)
                XCTAssertFalse(text.contains("BODYTWO")); XCTAssertTrue(text.contains("assets/image1.png"))
                for mapping in result.sourceMappings { XCTAssertEqual(mapping.output.file, "text.md"); XCTAssertNotNil(mapping.output.text(in: try Data(contentsOf: result.markdownFile))) }
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
    func testMissingUnsafeWrongTypeAndActionLinksKeepTextAndLocations() throws {
        let extra = """
        <a:r><a:rPr><a:hlinkClick r:id="bad"/></a:rPr><a:t>UNSAFE</a:t></a:r>
        <a:r><a:rPr><a:hlinkClick r:id="absent"/></a:rPr><a:t>MISSING</a:t></a:r>
        <a:r><a:rPr><a:hlinkClick r:id="image"/></a:rPr><a:t>WRONGTYPE</a:t></a:r>
        <a:r><a:rPr><a:hlinkClick r:id="missingSlide" action="ppaction://hlinksldjump"/></a:rPr><a:t>MISSINGSLIDE</a:t></a:r>
        <a:r><a:rPr><a:hlinkClick action="ppaction://macro?name=never"/></a:rPr><a:t>ACTION</a:t></a:r>
        """
        let source = root.appendingPathComponent("unsafe.pptx"); let bytes = try PresentationLinkFixture.data(ext: "pptx", extra: extra); try bytes.write(to: source)
        let result = try DocumentConverter().convert(.init(inputURL: source))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for token in ["UNSAFE", "MISSING", "WRONGTYPE", "MISSINGSLIDE", "ACTION"] { XCTAssertTrue(text.contains(token)) }
        XCTAssertFalse(destinations(text).contains { $0.contains("javascript") || $0.contains("macro") })
        let links = result.diagnostics.filter { $0.code.hasPrefix("presentation.link") }
        XCTAssertEqual(links.count, 5)
        XCTAssertTrue(links.allSatisfy { $0.location?.slide == 1 && $0.location?.paragraph == 1 && $0.kind == .contentLoss })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testODPMissingAmbiguousAndUnsafeTargetsRetainTheirLabels() throws {
        let extra = "<text:a xlink:href=\"#unknown\">MISSING</text:a><text:a xlink:href=\"javascript:never\">UNSAFE</text:a><text:a xlink:href=\"file:///tmp/never\">FILE</text:a>"
        let source = root.appendingPathComponent("bad.odp"); try PresentationLinkFixture.data(ext: "odp", extra: extra, duplicateName: true).write(to: source)
        let result = try DocumentConverter().convert(.init(inputURL: source)); let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for token in ["MISSING", "UNSAFE", "FILE", "JUMP_LABEL", "NOTE_JUMP"] { XCTAssertTrue(text.replacingOccurrences(of: "\\_", with: "_").contains(token)) }
        XCTAssertFalse(destinations(text).contains { $0.hasPrefix("#") || $0.hasPrefix("file:") || $0.hasPrefix("javascript:") })
        XCTAssertEqual(result.diagnostics.filter { $0.code == "presentation.linkUnavailable" }.count, 3)
        XCTAssertEqual(result.diagnostics.filter { $0.code == "presentation.linkUnsafe" }.count, 2)
    }
    func testMultilineLinksAndSplitBlockMarkersRemainSafeMarkdown() throws {
        var text = PresentationText("1")
        text.append(". item ")
        text.append("[a] |🙂\nsecond", target: "https://example.com/a(b)?a=1&b=2")
        text.append(" <script> ![x](javascript:never)")
        let paragraph = try text.markdown(table: false, maximumBytes: 100_000)
        XCTAssertTrue(paragraph.hasPrefix("1\\. item ")); XCTAssertEqual(destinations(paragraph).count, 2)
        XCTAssertFalse(paragraph.contains("<script>")); XCTAssertFalse(paragraph.contains("![x](javascript:"))
        let table = try PresentationRenderer.render(.init(blocks: [.table([[text]])]), number: 1)
        XCTAssertTrue(table.contains("<br>")); XCTAssertEqual(destinations(table).count, 2)
    }
    func testHyperlinkAndExpansionBudgetsFailAtomically() throws {
        let extra = String(repeating: "<text:a xlink:href=\"https://example.com\">BUDGET</text:a>", count: 8_193)
        let source = root.appendingPathComponent("limit.odp"); let bytes = try PresentationLinkFixture.data(ext: "odp", extra: extra); try bytes.write(to: source)
        let output = root.appendingPathComponent("never")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(output))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)); XCTAssertEqual(try Data(contentsOf: source), bytes)
        var text = PresentationText(); text.append(String(repeating: "x\n", count: 1_000), target: "https://example.com/" + String(repeating: "a", count: 1_000))
        XCTAssertThrowsError(try text.markdown(table: true, maximumBytes: 100_000))
    }
    private func changed(_ data: Data, part: String, transform: (String) -> String) throws -> Data {
        let path = root.appendingPathComponent(UUID().uuidString + ".zip"); try data.write(to: path)
        let reader = try ZIPArchiveInspector.inspectionSnapshot(at: path)
        let entries = try reader.entryNames.sorted().map { name -> ZIPFixtureBuilder.Entry in
            let bytes = try reader.data(named: name)
            return .init(name: name, content: name == part ? Data(transform(String(decoding: bytes, as: UTF8.self)).utf8) : bytes)
        }
        return try ZIPFixtureBuilder.archive(entries: entries)
    }
    func testShapeAndParagraphDefaultsRespectExplicitRunLinks() throws {
        let extra = "<a:r><a:rPr><a:hlinkClick r:id=\"bad\"/></a:rPr><a:t>BAD_OVERRIDE</a:t></a:r>"
        let bytes = try changed(PresentationLinkFixture.data(ext: "pptx", extra: extra), part: "ppt/slides/slide9.xml") {
            $0.replacingOccurrences(of: "<p:sp><p:txBody>", with: "<p:sp><p:nvSpPr><p:cNvPr><a:hlinkClick r:id=\"mail\"/></p:cNvPr></p:nvSpPr><p:txBody>")
                .replacingOccurrences(of: "<a:p><a:r><a:t>BODYONE", with: "<a:p><a:pPr><a:defRPr><a:hlinkClick r:id=\"web\"/></a:defRPr></a:pPr><a:r><a:t>BODYONE")
                .replacingOccurrences(of: "</p:txBody>", with: "<a:p><a:r><a:t>SHAPE_LABEL</a:t></a:r></a:p></p:txBody>")
        }
        let source = root.appendingPathComponent("defaults.pptx"); try bytes.write(to: source)
        let result = try DocumentConverter().convert(.init(inputURL: source)); let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("[BODYONE WEB\\_LABEL"), text)
        XCTAssertTrue(text.contains("[SHAPE\\_LABEL](mailto:review@example.com)"), text)
        XCTAssertTrue(text.replacingOccurrences(of: "\\_", with: "_").contains("BAD_OVERRIDE"), text)
        XCTAssertEqual(result.diagnostics.filter { $0.code == "presentation.linkUnsafe" }.count, 1)
    }
    func testStaticJumpActionsAndAmbiguousDefinitionsKeepHonestTargets() throws {
        let extra = """
        <a:r><a:rPr><a:hlinkClick action="ppaction://hlinkshowjump?jump=nextslide"/></a:rPr><a:t>NEXT</a:t></a:r>
        <a:r><a:rPr><a:hlinkClick action="ppaction://hlinkshowjump?jump=lastslideviewed"/></a:rPr><a:t>HISTORY</a:t></a:r>
        <a:r><a:rPr><a:hlinkClick r:id="web"/><a:hlinkClick r:id="mail"/></a:rPr><a:t>AMBIGUOUS</a:t></a:r>
        """
        let source = root.appendingPathComponent("jumps.pptx"); try PresentationLinkFixture.data(ext: "pptx", extra: extra).write(to: source)
        let result = try DocumentConverter().convert(.init(inputURL: source)); let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("NEXT](#pmt-slide-2)"), text)
        XCTAssertTrue(text.contains("HISTORY")); XCTAssertTrue(text.contains("AMBIGUOUS"))
        XCTAssertEqual(result.diagnostics.filter { $0.code == "presentation.linkActionNotRepresented" }.count, 1)
        XCTAssertEqual(result.diagnostics.filter { $0.code == "presentation.linkUnavailable" }.count, 1)
        let broken = try changed(PresentationLinkFixture.data(ext: "pptx"), part: "ppt/slides/_rels/slide9.xml.rels") {
            $0.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id=\"web\" Type=\"bad\" Target=\"bad\"/></Relationships>")
        }
        let bad = root.appendingPathComponent("duplicate.pptx"); try broken.write(to: bad); let output = root.appendingPathComponent("never")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: bad, destination: .directory(output))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)); XCTAssertEqual(try Data(contentsOf: bad), broken)
    }
    func testODPShapeTextLinksAndPercentEncodedSlideNames() throws {
        let data = try changed(PresentationLinkFixture.data(ext: "odp"), part: "content.xml") {
            $0.replacingOccurrences(of: "draw:name=\"Second\"", with: "draw:name=\"Second ä\"")
                .replacingOccurrences(of: "xlink:href=\"#Second\"", with: "xlink:href=\"#Second%20%C3%A4|page\"")
                .replacingOccurrences(of: "<text:p>BODYTWO</text:p>", with: "<draw:a xlink:href=\"mailto:review@example.com\"><draw:frame><draw:text-box><text:p>BODYTWO</text:p></draw:text-box></draw:frame></draw:a>")
        }
        let source = root.appendingPathComponent("names.odp"); try data.write(to: source)
        let result = try DocumentConverter().convert(.init(inputURL: source)); let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("[JUMP\\_LABEL](#pmt-slide-2)"), text)
        XCTAssertTrue(text.contains("[BODYTWO](mailto:review@example.com)"), text)
        XCTAssertFalse(result.diagnostics.contains { $0.code.hasPrefix("presentation.link") })
    }
    func testExternalTargetPolicyRejectsExecutableCredentialedAndMalformedDestinations() {
        for target in ["javascript:never", "data:text/html,never", "file:///tmp/never", "relative-file", "//example.com", "https://name:fake@example.com", "https://", "java\nscript:never", "https://example.com\\bad", String(repeating: "a", count: 8_193)] { XCTAssertNil(PresentationLinkTarget.external(target), target) }
        for target in ["https://example.com/a(b)?x=1&y=2", "http://example.com/ä", "mailto:review@example.com"] { XCTAssertEqual(PresentationLinkTarget.external(target), target) }
    }
}

enum PresentationLinkFixture {
    static let web = "https://example.com/a(b)?a=1&b=two words"
    static let webEncoded = "https://example.com/a%28b%29?a=1&b=two%20words"
    static var image: Data { get throws { try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/WordProcessing/fixture.png")) } }
    static func data(ext: String, extra: String = "", duplicateName: Bool = false) throws -> Data {
        let p = PresentationImport.presentation, a = PresentationImport.drawing, r = PresentationImport.relations
        let rel = "http://schemas.openxmlformats.org/package/2006/relationships"
        func entry(_ name: String, _ text: String) -> ZIPFixtureBuilder.Entry { .init(name: name, content: Data(text.utf8)) }
        if ext == "odp" {
            let body = """
            <office:document-content xmlns:office="\(PresentationImport.office)" xmlns:draw="\(PresentationImport.draw)" xmlns:text="\(PresentationImport.text)" xmlns:table="\(PresentationImport.table)" xmlns:xlink="\(PresentationImport.xlink)" xmlns:presentation="\(PresentationImport.presentationODF)"><office:body><office:presentation>
            <draw:page draw:name="\(duplicateName ? "Second" : "First")"><text:p>BODYONE <text:a xlink:href="https://example.com/a(b)?a=1&amp;b=two words">WEB_LABEL [x] |🙂</text:a> <text:a xlink:href="mailto:review@example.com">MAIL_LABEL</text:a> <text:a xlink:href="#Second">JUMP_LABEL</text:a>\(extra)</text:p>
            <table:table><table:table-row><table:table-cell><text:p><text:a xlink:href="https://example.com/a(b)?a=1&amp;b=two words">CELL_ONE</text:a> <text:a xlink:href="mailto:review@example.com">CELL_TWO</text:a></text:p></table:table-cell><table:table-cell><text:p>42</text:p></table:table-cell></table:table-row></table:table>
            <draw:frame><draw:image xlink:href="Pictures/image.png"/></draw:frame><presentation:notes><text:p><text:a xlink:href="https://example.com/a(b)?a=1&amp;b=two words">NOTE_WEB</text:a> <text:a xlink:href="#First">NOTE_JUMP</text:a></text:p></presentation:notes></draw:page>
            <draw:page draw:name="Second"><text:p>BODYTWO</text:p></draw:page></office:presentation></office:body></office:document-content>
            """
            return try ZIPFixtureBuilder.archive(entries: [entry("mimetype", "application/vnd.oasis.opendocument.presentation"), entry("content.xml", body), .init(name: "Pictures/image.png", content: image)])
        }
        func run(_ text: String, id: String, action: String = "") -> String { "<a:r><a:rPr><a:hlinkClick r:id=\"\(id)\"\(action.isEmpty ? "" : " action=\"\(action)\"")/></a:rPr><a:t>\(text)</a:t></a:r>" }
        func slide(_ content: String) -> String { "<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld><p:spTree>\(content)</p:spTree></p:cSld></p:sld>" }
        let body = "<p:sp><p:txBody><a:p><a:r><a:t>BODYONE </a:t></a:r>" + run("WEB_LABEL [x] |🙂", id: "web") + run(" MAIL_LABEL", id: "mail") + run(" JUMP_LABEL", id: "jump", action: "ppaction://hlinksldjump") + extra + "</a:p></p:txBody></p:sp>"
        let table = "<a:tbl><a:tr><a:tc><a:txBody><a:p>" + run("CELL_ONE", id: "web") + run(" CELL_TWO", id: "mail") + "</a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>42</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl>"
        let notes = "<p:notes xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld><p:spTree><p:sp><p:txBody><a:p>" + run("NOTE_WEB", id: "web") + run(" NOTE_JUMP", id: "jump", action: "ppaction://hlinksldjump") + "</a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>"
        let type = ext == "pptm" ? "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml" : ext == "potx" ? "application/vnd.openxmlformats-officedocument.presentationml.template.main+xml" : "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
        func relationships(_ extra: String) -> String { "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"web\" Type=\"\(r)/hyperlink\" Target=\"https://example.com/a(b)?a=1&amp;b=two words\" TargetMode=\"External\"/><Relationship Id=\"mail\" Type=\"\(r)/hyperlink\" Target=\"mailto:review@example.com\" TargetMode=\"External\"/>\(extra)</Relationships>" }
        let entries = [entry("[Content_Types].xml", "<Types xmlns=\"\(rel.replacingOccurrences(of: "relationships", with: "content-types"))\"><Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(type)\"/></Types>"), entry("ppt/presentation.xml", "<p:presentation xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:sldIdLst><p:sldId id=\"1\" r:id=\"first\"/><p:sldId id=\"2\" r:id=\"second\"/></p:sldIdLst></p:presentation>"), entry("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"first\" Type=\"\(r)/slide\" Target=\"slides/slide9.xml\"/><Relationship Id=\"second\" Type=\"\(r)/slide\" Target=\"slides/slide2.xml\"/></Relationships>"), entry("ppt/slides/slide9.xml", slide(body + table + "<p:pic><a:blip r:embed=\"image\"/></p:pic>")), entry("ppt/slides/slide2.xml", slide("<p:sp><p:txBody><a:p><a:r><a:t>BODYTWO</a:t></a:r></a:p></p:txBody></p:sp>")), entry("ppt/slides/_rels/slide9.xml.rels", relationships("<Relationship Id=\"jump\" Type=\"\(r)/slide\" Target=\"slide2.xml\"/><Relationship Id=\"notes\" Type=\"\(r)/notesSlide\" Target=\"../notesSlides/notes.xml\"/><Relationship Id=\"image\" Type=\"\(r)/image\" Target=\"../media/image.png\"/><Relationship Id=\"bad\" Type=\"\(r)/hyperlink\" Target=\"javascript:never\" TargetMode=\"External\"/><Relationship Id=\"missingSlide\" Type=\"\(r)/slide\" Target=\"absent.xml\"/>")), entry("ppt/notesSlides/notes.xml", notes), entry("ppt/notesSlides/_rels/notes.xml.rels", relationships("<Relationship Id=\"jump\" Type=\"\(r)/slide\" Target=\"../slides/slide9.xml\"/>")), ZIPFixtureBuilder.Entry(name: "ppt/media/image.png", content: try image)]
        return try ZIPFixtureBuilder.archive(entries: entries)
    }
}
