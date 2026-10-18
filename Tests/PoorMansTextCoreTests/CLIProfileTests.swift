import Foundation
import Markdown
import XCTest
@testable import PoorMansTextCore

final class CLIProfileTests: XCTestCase {
    private var root: URL!
    private var store: URL { root.appendingPathComponent("profiles") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCLIProfiles-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func run(_ arguments: [String], profiles: Bool = true) throws -> ProcessResult {
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("poormans-text")
        return try ProcessRunner.run(executable: cli,arguments: (profiles ? ["--profiles-directory",store.path] : []) + arguments,currentDirectory: root,captureStandardOutput: true,timeout: 30)
    }
    private func json(_ result: ProcessResult, status: Int32 = 0) throws -> [String: Any] {
        XCTAssertEqual(result.status,status,result.standardOutput + result.standardError)
        XCTAssertTrue(result.standardError.isEmpty,result.standardError)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
    }
    private func plain(_ source: String) -> String {
        var text = ""
        func visit(_ node: any Markup) {
            if let node = node as? Markdown.Text { text += node.string + " " }
            if let node = node as? CodeBlock { text += node.code + " " }
            if let node = node as? InlineCode { text += node.code + " " }
            for child in node.children { visit(child) }
        }
        visit(Document(parsing: source)); return text
    }
    func testSaveListExportImportAndCollisionsPreserveOriginalProfile() throws {
        _ = try json(run(["--save-profile","Reusable","--spreadsheet-format","tsv","--docx-changes","mark","--json"]))
        let list = try json(run(["--list-profiles","--json"]))
        let summaries = try XCTUnwrap(list["profiles"] as? [[String: Any]])
        XCTAssertEqual(summaries.count,1); XCTAssertEqual(summaries[0]["name"] as? String,"Reusable"); XCTAssertEqual(summaries[0]["scope"] as? String,"portable")
        let path = root.appendingPathComponent("portable.json")
        _ = try json(run(["--profile","reusable","--export-profile",path.path,"--json"]))
        let original = try Data(contentsOf: path), profile = try ConversionProfile.decode(original)
        XCTAssertEqual(profile.options.docxChangeMode,.mark)
        XCTAssertFalse(String(decoding: original,as: UTF8.self).contains(root.path))
        _ = try json(run(["--save-profile","REUSABLE","--json"]),status: 73)
        _ = try json(run(["--profile","Reusable","--export-profile",path.path,"--json"]),status: 73)
        XCTAssertEqual(try Data(contentsOf: path),original)
        let other = root.appendingPathComponent("other-store")
        _ = try json(run(["--profiles-directory",other.path,"--import-profile",path.path,"--json"],profiles: false))
        XCTAssertEqual(try ConversionProfileStore(directory: other).load(named: "Reusable"),profile)
    }
    func testExplicitOptionsWinRegardlessOfProfileArgumentOrder() throws {
        let source = root.appendingPathComponent("values.csv");try Data("Name,Value\nOverrideBody,42\n".utf8).write(to: source)
        _ = try json(run(["--save-profile","Base","--spreadsheet-format","tsv","--frontmatter","--textbundle","--report","--source-map","--json"]))
        var outputs: [Data] = []
        for profileFirst in [true,false] {
            let destination = root.appendingPathComponent(profileFirst ? "first" : "second")
            let overrides = ["--spreadsheet-format","table","--no-frontmatter","--markdown-folder","--no-report","--no-source-map"]
            let args = (profileFirst ? ["--profile","Base"] + overrides : overrides + ["--profile","Base"]) + ["--json","-o",destination.path,source.path]
            let response = try json(run(args)), markdown = URL(fileURLWithPath: try XCTUnwrap(response["markdownFile"] as? String))
            let data = try Data(contentsOf: markdown); outputs.append(data)
            XCTAssertTrue(String(decoding: data,as: UTF8.self).contains("| OverrideBody | 42 |"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("conversion-report.json").path))
            XCTAssertEqual(markdown.lastPathComponent,"values.md")
        }
        XCTAssertEqual(outputs[0],outputs[1])
    }
    func testRealPDFCSVPresentationAndDOCXMatchExplicitEffectiveOptions() throws {
        let pdf = try PDFAnnotationFixture.make(in: root), docx = try DOCXReviewFixture.make(in: root)
        let csv = root.appendingPathComponent("values.csv"); try Data("Name,Value\nCSVPROFILEBODY,42\n".utf8).write(to: csv)
        let pptx = root.appendingPathComponent("links.pptx"); try PresentationLinkFixture.data(ext: "pptx").write(to: pptx)
        let flags = ["--spreadsheet-format","tsv","--image-ocr","off","--frontmatter","--textbundle","--pdf-ocr","off","--pdf-layout","legacy","--docx-changes","mark","--report","--source-map"]
        _ = try json(run(["--save-profile","Portable"] + flags + ["--json"]))
        if let path = ProcessInfo.processInfo.environment["PMT_PROFILE_MATRIX_DIR"] {
            let export = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: export,withIntermediateDirectories: true)
            let sources = export.appendingPathComponent("sources")
            try FileManager.default.createDirectory(at: sources,withIntermediateDirectories: false)
            for source in [pdf,csv,pptx,docx] {
                try FileManager.default.copyItem(at: source,to: sources.appendingPathComponent(source.lastPathComponent))
            }
            try PresentationLinkFixture.image.write(to: export.appendingPathComponent("reference.png"))
            let profiles = ConversionProfileStore(directory: store)
            try ConversionProfileStore.export(profiles.load(named: "Portable"),to: export.appendingPathComponent("portable.json"))
        }
        var receipts: [[String: Any]] = []
        for source in [pdf,csv,pptx,docx] {
            let original = try Data(contentsOf: source), name = source.pathExtension
            var outputs: [Data] = [], reports: [ConversionReport] = []
            for usesProfile in [false,true] {
                let destination = root.appendingPathComponent(name + (usesProfile ? "-profile.textbundle" : "-explicit.textbundle"))
                let args = (usesProfile ? ["--profile","Portable"] : flags) + ["--json","-o",destination.path,source.path]
                let response = try json(run(args,profiles: usesProfile))
                let markdown = URL(fileURLWithPath: try XCTUnwrap(response["markdownFile"] as? String)), data = try Data(contentsOf: markdown)
                let report = try JSONDecoder().decode(ConversionReport.self,from: Data(contentsOf: destination.appendingPathComponent("conversion-report.json")))
                outputs.append(data); reports.append(report)
                let decoded = plain(String(decoding: data,as: UTF8.self).components(separatedBy: "## Document comments")[0])
                let token = name == "csv" ? "CSVPROFILEBODY" : name == "pdf" ? "BODY_TWO" : name == "pptx" ? "BODYTWO" : "INSERTONLY"
                XCTAssertEqual(decoded.components(separatedBy: token).count - 1,1,decoded)
                XCTAssertEqual(try Data(contentsOf: source),original)
                XCTAssertEqual(report.source.sha256,ConversionFileFingerprint.digest(original))
                let assets = try XCTUnwrap(response["assets"] as? [String])
                XCTAssertEqual(assets.count,["pptx","docx"].contains(name) ? 1 : 0)
                for asset in assets {
                    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: asset)),try PresentationLinkFixture.image)
                }
                if let path = ProcessInfo.processInfo.environment["PMT_PROFILE_MATRIX_DIR"] {
                    let export = URL(fileURLWithPath: path)
                    try FileManager.default.copyItem(at: destination,to: export.appendingPathComponent(destination.lastPathComponent))
                }
            }
            XCTAssertEqual(outputs[0],outputs[1])
            let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(reports[0].options),try encoder.encode(reports[1].options))
            XCTAssertEqual(reports[0].outputs,reports[1].outputs)
            receipts.append(["format":name,"outputSHA256":ConversionFileFingerprint.digest(outputs[0]),"sourceSHA256":ConversionFileFingerprint.digest(original),"effectiveOptionsEqual":true,"outputManifestEqual":true])
        }
        if let path = ProcessInfo.processInfo.environment["PMT_PROFILE_MATRIX_DIR"] {
            try JSONSerialization.data(withJSONObject: receipts,options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path).appendingPathComponent("matrix.json"))
        }
    }
    func testBoundSelectionRejectsOtherBytesAndCanBeClearedForStdout() throws {
        let source = try PDFAnnotationFixture.make(in: root)
        _ = try json(run(["--save-profile","Bound","--pdf-pages","2","--pdf-ocr","off","--profile-source",source.path,"--json"]))
        let selected = try run(["--profile","Bound","--stdout",source.path])
        XCTAssertEqual(selected.status,0,selected.standardError); XCTAssertTrue(selected.standardOutput.contains("BODY\\_TWO")); XCTAssertFalse(selected.standardOutput.contains("BODY\\_ONE"))
        let changed = root.appendingPathComponent("changed.pdf");try (Data(contentsOf: source) + Data("\n%changed\n".utf8)).write(to: changed)
        _ = try json(run(["--profile","Bound","--json","-o",root.appendingPathComponent("never").path,changed.path]),status: 65)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("never").path))
        let cleared = try run(["--profile","Bound","--clear-profile-selection","--stdout",changed.path])
        XCTAssertEqual(cleared.status,0,cleared.standardError); XCTAssertTrue(cleared.standardOutput.contains("BODY\\_ONE"))
        _ = try json(run(["--save-profile","UnsafeSelection","--pdf-pages","1","--json"]),status: 65)
    }
    func testLocalProfileImportExportAndApplicationRequireOptIn() throws {
        let destination = root.appendingPathComponent("local-output"), source = root.appendingPathComponent("values.csv")
        try Data("Name,Value\nLocalBody,42\n".utf8).write(to: source)
        _ = try json(run(["--save-profile","Local","-o",destination.path,"--json"]),status: 64)
        _ = try json(run(["--save-profile","Local","--profile-local","-o",destination.path,"--json"]))
        _ = try json(run(["--profile","Local","--json",source.path]),status: 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let export = root.appendingPathComponent("local.json")
        _ = try json(run(["--profile","Local","--export-profile",export.path,"--json"]),status: 64)
        _ = try json(run(["--profile","Local","--profile-local","--export-profile",export.path,"--json"]))
        _ = try json(run(["--profiles-directory",root.appendingPathComponent("other").path,"--import-profile",export.path,"--json"],profiles: false),status: 64)
        _ = try json(run(["--profile","Local","--profile-local","--json",source.path]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("values.md").path))
    }
    func testProfileModesMalformedImportAndValueScanFailBeforeSideEffects() throws {
        for flags in [["--list-profiles","--save-profile","Conflict"],["--list-profiles","--frontmatter"],["--profile-source",root.path],["--profile-local"],["--clear-profile-selection"],["--profile","Missing","--formats"]] {
            _ = try json(run(flags + ["--json"]),status: 64)
        }
        let invalid = root.appendingPathComponent("invalid.json");try Data(#"{"schemaVersion":1,"name":"Bad","options":{"secret":"never"}}"#.utf8).write(to: invalid)
        _ = try json(run(["--import-profile",invalid.path,"--json"]),status: 65)
        try Data(repeating: 32,count: ConversionProfile.maximumBytes + 1).write(to: invalid)
        _ = try json(run(["--import-profile",invalid.path,"--json"]),status: 65)
        for option in ["--profile","--save-profile","--import-profile","--export-profile","--profiles-directory","--profile-source"] {
            let result = try run([option,"--json","--invalid-profile-test-option"])
            XCTAssertEqual(result.status,64); XCTAssertTrue(result.standardOutput.isEmpty)
        }
        XCTAssertEqual(try ConversionProfileStore(directory: store).profiles(),[])
    }
}
