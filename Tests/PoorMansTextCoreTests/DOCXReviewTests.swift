import Foundation
import XCTest
@testable import PoorMansTextCore

final class DOCXReviewTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DOCXReviewTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRealDOCXModesPreserveCommentsNotesTablesAndImageBytes() throws {
        let source = try DOCXReviewFixture.make(in: root)
        let sourceBytes = try Data(contentsOf: source)
        let imageBytes = try Data(contentsOf: DOCXReviewFixture.fixture("fixture.png"))
        var receipts: [[String: Any]] = []
        for mode in [DOCXChangeMode.accept, .reject, .mark] {
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(mode.rawValue)),
                options: .init(docxChangeMode: mode, conversionReport: true)))
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            let body = markdown.components(separatedBy: "## Document comments")[0]
            let expected = mode == .accept ? ["INSERTONLY", "NEWPARA", "NEWROWONE", "NEWROWTWO", "TCNEW", "NOTE_NEW", "END_NEW"] :
                mode == .reject ? ["DELETEONLY", "DELPARA", "DELROWONE", "DELROWTWO", "TCOLD", "NOTE_OLD", "END_OLD", "DELCOMMENT"] :
                ["INSERTONLY", "NEWPARA", "NEWROWONE", "NEWROWTWO", "TCNEW", "NOTE_NEW", "END_NEW", "DELETEONLY", "DELPARA", "DELROWONE", "DELROWTWO", "TCOLD", "NOTE_OLD", "END_OLD", "DELCOMMENT"]
            let vocabulary = ["INSERTONLY", "NEWPARA", "NEWROWONE", "NEWROWTWO", "TCNEW", "NOTE_NEW", "END_NEW", "DELETEONLY", "DELPARA", "DELROWONE", "DELROWTWO", "TCOLD", "NOTE_OLD", "END_OLD", "DELCOMMENT"]
            var counts: [String: Int] = [:]
            for word in vocabulary {
                counts[word] = body.components(separatedBy: word).count - 1
                XCTAssertEqual(counts[word], expected.contains(word) ? 1 : 0, "\(mode) \(word)\n\(markdown)")
            }
            XCTAssertEqual(body.components(separatedBy: "MOVEDWORD").count - 1, mode == .mark ? 2 : 1, markdown)
            for word in ["STABLE_BODY", "STABLE_CELL", "STABLE_NOTE", "STYLE_BODY", "Footnote content remains readable."] {
                XCTAssertEqual(body.components(separatedBy: word).count - 1, 1, markdown)
            }
            for number in 1...6 {
                XCTAssertEqual(markdown.components(separatedBy: "### Comment \(number)\n").count - 1, 1, markdown)
                XCTAssertEqual(markdown.replacingOccurrences(of: "\\_", with: "_").components(separatedBy: "COMMENT_BODY_\(number)").count - 1, 1, markdown)
                XCTAssertTrue(markdown.contains("Reviewer\(number)"), markdown)
                XCTAssertTrue(markdown.contains("2026-10-16T09:00:0\(number)Z"), markdown)
            }
            XCTAssertTrue(markdown.contains("Source excerpt: SharedANCHOROverlapANCHOR"), markdown)
            XCTAssertTrue(markdown.contains("Source excerpt: OverlapANCHOROtherANCHOR"), markdown)
            XCTAssertTrue(markdown.contains("Source excerpt: \\[Image\\]") || markdown.contains("Source excerpt: [Image]"), markdown)
            XCTAssertEqual(result.diagnostics.filter { $0.code == "docx.commentPreserved" }.count, 6)
            XCTAssertTrue(result.diagnostics.contains { $0.code == "docx.commentDetached" && $0.location?.note == "Comment 6" })
            XCTAssertEqual(result.diagnostics.contains { $0.code == "docx.commentDetached" && $0.location?.note == "Comment 5" }, mode == .accept)
            XCTAssertTrue(result.diagnostics.contains { $0.code == "docx.formatChangeNotRepresented" })
            XCTAssertFalse(result.diagnostics.contains { $0.code == "wordProcessing.commentsNotPreserved" })
            if mode == .mark {
                for label in ["Insertion; Editor", "Deletion; Editor", "Move from; Editor", "Move to; Editor", "paragraph break", ": row"] { XCTAssertTrue(markdown.contains(label), markdown) }
                XCTAssertFalse(result.diagnostics.contains { $0.code == "docx.changeAnchorUnavailable" }, "\(result.diagnostics)")
            }
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), imageBytes)
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: result.outputDirectory.appendingPathComponent("conversion-report.json")))
            XCTAssertEqual(report.options.docxChangeMode, mode)
            XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(sourceBytes))
            let markdownBytes = try Data(contentsOf: result.markdownFile)
            XCTAssertGreaterThanOrEqual(report.sourceMappings.count, 6)
            for mapping in report.sourceMappings { XCTAssertNotNil(mapping.output.text(in: markdownBytes)); XCTAssertNotNil(mapping.source.note ?? mapping.source.paragraph.map(String.init)) }
            var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: result.outputDirectory.appendingPathComponent("conversion-report.json"))) as? [String: Any])
            var options = old["options"] as! [String: Any]; options.removeValue(forKey: "docxChangeMode"); old["options"] = options
            XCTAssertNil(try JSONDecoder().decode(ConversionReport.self, from: JSONSerialization.data(withJSONObject: old)).options.docxChangeMode)
            receipts.append(["mode": mode.rawValue, "counts": counts, "comments": 6, "sourceSHA256": ConversionFileFingerprint.digest(sourceBytes), "assetSHA256": ConversionFileFingerprint.digest(imageBytes), "diagnostics": result.diagnostics.map(\.code), "mappings": report.sourceMappings.count])
            if let path = ProcessInfo.processInfo.environment["PMT_DOCX_REVIEW_DIR"] {
                let export = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
                let destination = export.appendingPathComponent(mode.rawValue)
                if FileManager.default.fileExists(atPath: destination.path) { throw ImportFailure("the DOCX review export must be a fresh directory") }
                try FileManager.default.copyItem(at: result.outputDirectory, to: destination)
            }
        }
        if let path = ProcessInfo.processInfo.environment["PMT_DOCX_REVIEW_DIR"] {
            let export = URL(fileURLWithPath: path)
            try sourceBytes.write(to: export.appendingPathComponent("review.docx"))
            try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys]).write(to: export.appendingPathComponent("matrix.json"))
        }
    }

    func testCommentRelationshipResolvesCustomPartAndReportsBrokenReferences() throws {
        let source = try DOCXReviewFixture.make(in: root, commentsName: "review-notes.xml", commentsOverride: "<w:comment w:id=\"1\" w:author=\"Only\"><w:p><w:r><w:t>ONLY_DEFINITION</w:t></w:r></w:p></w:comment>", customNotes: true)
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("custom"))))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.replacingOccurrences(of: "\\_", with: "_").contains("ONLY_DEFINITION"))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "docx.commentDefinitionMissing" && $0.kind == .contentLoss })
        XCTAssertTrue(markdown.contains("Missing comment definition"))
        XCTAssertTrue(markdown.contains("NOTE_NEW"))
        XCTAssertTrue(markdown.contains("END_NEW"))
        XCTAssertEqual(markdown.components(separatedBy: "](images/image01.png)").count - 1, 3, markdown)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), try Data(contentsOf: DOCXReviewFixture.fixture("fixture.png")))
    }

    func testDuplicateCommentIdentifiersAndExternalCommentPartsFailAtomically() throws {
        for external in [false, true] {
            let folder = root.appendingPathComponent(external ? "external" : "duplicate"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let source = try DOCXReviewFixture.make(in: folder, commentsOverride: "<w:comment w:id=\"1\"/><w:comment w:id=\"1\"/>", externalComments: external)
            let bytes = try Data(contentsOf: source)
            let output = folder.appendingPathComponent("result")
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(output))))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [source.lastPathComponent])
        }
    }

    func testReviewTextIsLiteralAndTextbundleMappingsRemainValid() throws {
        let source = try DOCXReviewFixture.make(in: root, commentsOverride: "<w:comment w:id=\"1\" w:author=\"&lt;script&gt; [Author](https://invalid.test)\"><w:p><w:r><w:t>&lt;script&gt;alert(1)&lt;/script&gt; [COMMENT](javascript:bad) **bold**</w:t></w:r></w:p></w:comment>", changeAuthor: "Editor **[link](javascript:bad)** <script>")
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("bundle.textbundle")), options: .init(frontmatter: true, outputLayout: .textbundle, docxChangeMode: .mark, conversionReport: true)))
        let bytes = try Data(contentsOf: result.markdownFile); let markdown = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(markdown.contains("<script>"), markdown)
        XCTAssertTrue(markdown.contains("\\[COMMENT\\]"), markdown)
        XCTAssertTrue(markdown.contains("\\*\\*bold\\*\\*"), markdown)
        XCTAssertFalse(markdown.contains("**[link](javascript:bad)**"), markdown)
        XCTAssertTrue(markdown.contains("assets/"), markdown)
        for mapping in result.sourceMappings { XCTAssertEqual(mapping.output.file, "text.md"); XCTAssertNotNil(mapping.output.text(in: bytes)) }
    }

    func testNonDOCXFormatsKeepExistingBehavior() throws {
        for file in ["annotated.odt", "textutil.doc"] {
            let source = DOCXReviewFixture.fixture(file)
            let a = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(file + "-accept"))))
            let b = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(file + "-reject")), options: .init(docxChangeMode: .reject)))
            XCTAssertEqual(try Data(contentsOf: a.markdownFile), try Data(contentsOf: b.markdownFile))
            XCTAssertEqual(a.diagnostics, b.diagnostics)
        }
    }

    func testOversizedCommentCollectionFailsWithoutPublishingOrChangingSource() throws {
        let comments = (0...4_096).map { "<w:comment w:id=\"\($0)\"><w:p><w:r><w:t>Small</w:t></w:r></w:p></w:comment>" }.joined()
        let source = try DOCXReviewFixture.make(in: root, commentsOverride: comments)
        let bytes = try Data(contentsOf: source)
        let output = root.appendingPathComponent("oversized")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(output)))) { error in
            XCTAssertTrue(error.localizedDescription.contains("4096"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    func testPointAndIncompleteCommentRangesKeepTheirReferenceWithoutInventingAnInterval() throws {
        let definitions = "<w:comment w:id=\"42\"><w:p><w:r><w:t>Point comment</w:t></w:r></w:p></w:comment><w:comment w:id=\"43\"><w:p><w:r><w:t>Incomplete comment</w:t></w:r></w:p></w:comment>"
        let extra = "<w:p><w:r><w:commentReference w:id=\"42\"/></w:r></w:p><w:p><w:commentRangeStart w:id=\"43\"/><w:r><w:t>UNFINISHED_RANGE</w:t></w:r></w:p>"
        let source = try DOCXReviewFixture.make(in: root, commentsOverride: definitions, extraBody: extra)
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("points"))))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Point comment"))
        XCTAssertTrue(markdown.contains("Source reference: no textual range available."))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "docx.commentAnchorIncomplete" && $0.location?.note == "Comment 2" })
        XCTAssertFalse(result.diagnostics.contains { $0.code == "docx.commentDetached" && $0.location?.note == "Comment 1" })
    }

    func testUTCReviewDatesAreRetainedAlongsideOriginalDates() throws {
        let namespace = "http://schemas.microsoft.com/office/word/2023/wordml/word16du"
        let definitions = "<w:comment xmlns:u=\"\(namespace)\" w:id=\"1\" w:date=\"2026-10-15T11:00:00+02:00\" u:dateUtc=\"2026-10-15T09:00:00Z\"><w:p><w:r><w:t>Both dates</w:t></w:r></w:p></w:comment><w:comment xmlns:u=\"\(namespace)\" w:id=\"2\" u:dateUtc=\"2026-10-17T01:02:03Z\"><w:p><w:r><w:t>UTC only</w:t></w:r></w:p></w:comment>"
        let extra = "<w:p><w:ins xmlns:u=\"\(namespace)\" w:id=\"800\" w:author=\"UTC Editor\" w:date=\"2026-10-16T11:00:00+02:00\" u:dateUtc=\"2026-10-16T09:00:00Z\"><w:r><w:t>UTC_INSERT</w:t></w:r></w:ins></w:p>"
        let source = try DOCXReviewFixture.make(in: root, commentsOverride: definitions, extraBody: extra)
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("utc")), options: .init(docxChangeMode: .mark)))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for date in ["2026-10-15T11:00:00+02:00", "2026-10-15T09:00:00Z", "2026-10-17T01:02:03Z", "2026-10-16T11:00:00+02:00", "2026-10-16T09:00:00Z"] { XCTAssertTrue(markdown.contains(date), markdown) }
        XCTAssertTrue(markdown.contains("UTC only"))
    }
}

enum DOCXReviewFixture {
    static func fixture(_ name: String) -> URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/" + name) }
    static func make(in directory: URL, commentsName: String = "comments.xml", commentsOverride: String? = nil, externalComments: Bool = false, customNotes: Bool = false, changeAuthor: String = "Editor", extraBody: String = "") throws -> URL {
        let source = try ZIPArchiveInspector.inspectionSnapshot(at: fixture("pandoc.docx"))
        var entries: [String: Data] = [:]
        for name in source.entryNames { entries[name] = try source.data(named: name) }
        var document = String(decoding: entries["word/document.xml"]!, as: UTF8.self)
        let imageRegex = try NSRegularExpression(pattern: "<w:drawing[\\s\\S]*?</w:drawing>")
        let imageRange = try XCTUnwrap(imageRegex.firstMatch(in: document, range: NSRange(document.startIndex..., in: document)).flatMap { Range($0.range, in: document) })
        let image = String(document[imageRange])
        func run(_ text: String, deleted: Bool = false) -> String { "<w:r><w:\(deleted ? "delText" : "t") xml:space=\"preserve\">\(text)</w:\(deleted ? "delText" : "t")></w:r>" }
        let author = changeAuthor.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        var revisionID = 100
        func change(_ name: String, _ text: String) -> String {
            revisionID += 1
            return "<w:\(name) w:id=\"\(revisionID)\" w:author=\"\(author)\" w:date=\"2026-10-16T10:11:12Z\">\(run(text, deleted: name == "del"))</w:\(name)>"
        }
        func cell(_ text: String) -> String { "<w:tc><w:p>\(run(text))</w:p></w:tc>" }
        let paragraphs = """
        <w:p>\(run("STABLE_BODY "))<w:commentRangeStart w:id="1"/>\(run("SharedANCHOR"))<w:commentRangeStart w:id="2"/>\(run("OverlapANCHOR"))<w:commentRangeEnd w:id="1"/>\(run("OtherANCHOR"))<w:commentRangeEnd w:id="2"/><w:r><w:commentReference w:id="1"/><w:commentReference w:id="2"/></w:r></w:p>
        <w:p>\(change("ins", "INSERTONLY"))\(change("del", "DELETEONLY"))\(change("moveFrom", "MOVEDWORD"))\(change("moveTo", "MOVEDWORD"))</w:p>
        <w:p><w:pPr><w:rPr><w:del w:id="51" w:author="Editor"/></w:rPr></w:pPr>\(change("del", "DELPARA"))</w:p>
        <w:p><w:pPr><w:rPr><w:ins w:id="52" w:author="Editor"/></w:rPr></w:pPr>\(change("ins", "NEWPARA"))</w:p>
        <w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>
        <w:tr>\(cell("STABLE_CELL"))\(cell("StableValue"))</w:tr>
        <w:tr><w:trPr><w:del w:id="53" w:author="Editor"/></w:trPr>\(cell("DELROWONE"))\(cell("DELROWTWO"))</w:tr>
        <w:tr><w:trPr><w:ins w:id="54" w:author="Editor"/></w:trPr>\(cell("NEWROWONE"))\(cell("NEWROWTWO"))</w:tr>
        <w:tr><w:tc><w:p>\(change("ins", "TCNEW"))\(change("del", "TCOLD"))</w:p></w:tc>\(cell("CellValue"))</w:tr></w:tbl>
        <w:p><w:commentRangeStart w:id="3"/><w:r>\(image)</w:r><w:commentRangeEnd w:id="3"/><w:r><w:commentReference w:id="3"/></w:r></w:p>
        <w:p><w:del w:id="55" w:author="Editor"><w:commentRangeStart w:id="5"/>\(run("DELCOMMENT", deleted: true))<w:commentRangeEnd w:id="5"/><w:r><w:commentReference w:id="5"/></w:r></w:del></w:p>
        <w:p>\(run("Review notes"))<w:r><w:footnoteReference w:id="11"/><w:endnoteReference w:id="11"/></w:r></w:p>
        <w:p><w:r><w:rPr><w:b/><w:rPrChange w:id="56" w:author="Stylist" w:date="2026-10-16T12:00:00Z"><w:rPr/></w:rPrChange></w:rPr><w:t>STYLE_BODY</w:t></w:r></w:p>
        """
        let end = try XCTUnwrap(document.range(of: "<w:sectPr")); document.insert(contentsOf: paragraphs + extraBody, at: end.lowerBound)
        entries["word/document.xml"] = Data(document.utf8)
        var footnotes = String(decoding: entries["word/footnotes.xml"]!, as: UTF8.self)
        footnotes = footnotes.replacingOccurrences(of: "</w:footnotes>", with: "<w:footnote w:id=\"11\"><w:p><w:commentRangeStart w:id=\"4\"/>\(run("STABLE_NOTE"))<w:commentRangeEnd w:id=\"4\"/><w:r><w:commentReference w:id=\"4\"/></w:r>\(change("ins", "NOTE_NEW"))\(change("del", "NOTE_OLD"))\(customNotes ? "<w:r>" + image + "</w:r>" : "")</w:p></w:footnote></w:footnotes>")
        entries["word/footnotes.xml"] = Data(footnotes.utf8)
        entries["word/endnotes.xml"] = Data("<w:endnotes xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:endnote w:id=\"11\"><w:p>\(change("ins", "END_NEW"))\(change("del", "END_OLD"))</w:p></w:endnote></w:endnotes>".utf8)
        let comments = commentsOverride ?? (1...6).map { "<w:comment w:id=\"\($0)\" w:author=\"Reviewer\($0)\" w:date=\"2026-10-16T09:00:0\($0)Z\"><w:p>\(run("COMMENT_BODY_\($0)"))</w:p></w:comment>" }.joined()
        entries.removeValue(forKey: "word/comments.xml")
        entries["word/" + commentsName] = Data("<w:comments xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(comments)</w:comments>".utf8)
        var relations = String(decoding: entries["word/_rels/document.xml.rels"]!, as: UTF8.self)
        relations = relations.replacingOccurrences(of: "Target=\"comments.xml\"", with: externalComments ? "Target=\"https://invalid.test/comments.xml\" TargetMode=\"External\"" : "Target=\"\(commentsName)\"")
        relations = relations.replacingOccurrences(of: "</Relationships>", with: "<Relationship Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes\" Id=\"pmtEndnotes\" Target=\"endnotes.xml\"/></Relationships>")
        entries["word/_rels/document.xml.rels"] = Data(relations.utf8)
        var types = String(decoding: entries["[Content_Types].xml"]!, as: UTF8.self).replacingOccurrences(of: "/word/comments.xml", with: "/word/" + commentsName)
        types = types.replacingOccurrences(of: "</Types>", with: "<Override PartName=\"/word/endnotes.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.endnotes+xml\"/></Types>")
        entries["[Content_Types].xml"] = Data(types.utf8)
        if customNotes {
            for name in ["footnotes", "endnotes"] {
                entries["word/notes/" + name + "-review.xml"] = entries.removeValue(forKey: "word/" + name + ".xml")
                entries["word/notes/_rels/" + name + "-review.xml.rels"] = entries.removeValue(forKey: "word/_rels/" + name + ".xml.rels")
                relations = relations.replacingOccurrences(of: "Target=\"" + name + ".xml\"", with: "Target=\"notes/" + name + "-review.xml\"")
                types = types.replacingOccurrences(of: "/word/" + name + ".xml", with: "/word/notes/" + name + "-review.xml")
            }
            entries["word/_rels/document.xml.rels"] = Data(relations.utf8)
            entries["[Content_Types].xml"] = Data(types.utf8)
            entries["word/notes/_rels/footnotes-review.xml.rels"] = Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId11\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/rId11.png\"/></Relationships>".utf8)
        }
        let output = directory.appendingPathComponent("review.docx")
        try ZIPFixtureBuilder.archive(entries: entries.keys.sorted().map { .init(name: $0, content: entries[$0]!) }).write(to: output)
        return output
    }
}
