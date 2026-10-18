import AppKit
import AppIntents
import Markdown
import XCTest
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

@MainActor
final class AppProfileTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ConversionProfileStore { .init(directory: root.appendingPathComponent("profiles")) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppProfiles-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        suite = "AppProfiles-\(UUID())"; defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite); try FileManager.default.removeItem(at: root)
    }
    private func model() -> AppModel { .init(defaults: defaults, profileStore: store) }
    private func csv() throws -> URL {
        let url = root.appendingPathComponent("values.csv")
        try Data("Name,Value\nPROFILEBODY,42\n".utf8).write(to: url); return url
    }
    private func wait(_ model: AppModel) async throws {
        let end = Date().addingTimeInterval(30)
        while model.isConverting && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isConverting)
    }
    func testLegacyPreferencesSurviveManagementAndUnsavedRestart() throws {
        defaults.set(SpreadsheetRendering.tabSeparated.rawValue, forKey: "spreadsheetRendering"); defaults.set(true, forKey: "frontmatter")
        defaults.set("mark", forKey: "docxChangeMode"); defaults.set(3, forKey: "batchParallelism")
        defaults.set(root.path, forKey: "destinationFolder")
        let app = model(), before = app.conversionOptions
        XCTAssertEqual(before.spreadsheetRendering, .tabSeparated)
        XCTAssertTrue(before.sourceMapping); XCTAssertTrue(before.presentationIncludeNotes)
        XCTAssertFalse(before.conversionReport); XCTAssertTrue(try store.profiles().isEmpty)
        try app.saveProfile(named: "Review")
        XCTAssertFalse(app.hasUnsavedProfileChanges); XCTAssertEqual(app.conversionOptions, before)
        app.docxChangeMode = .reject
        XCTAssertTrue(app.hasUnsavedProfileChanges)
        let restored = model()
        XCTAssertEqual(restored.selectedProfileName, "Review"); XCTAssertTrue(restored.hasUnsavedProfileChanges)
        XCTAssertEqual(restored.docxChangeMode, .reject); XCTAssertEqual(restored.batchParallelism, 3)
        XCTAssertEqual(restored.destinationFolder?.path, root.path)
        try restored.updateSelectedProfile(); XCTAssertFalse(restored.hasUnsavedProfileChanges)
        try restored.saveProfile(named: "Copy", duplicateSelected: true)
        XCTAssertEqual(try store.load(named: "Copy").options.docxChangeMode, .reject)
        try restored.deleteSelectedProfile()
        XCTAssertNil(restored.selectedProfileName); XCTAssertEqual(restored.docxChangeMode, .reject)
        XCTAssertEqual(try store.profiles().map(\.name), ["Review"])
    }
    func testStaleUpdateDeleteAndMissingProfilesPreserveCurrentValues() throws {
        let app = model(); try app.saveProfile(named: "Original")
        let original = try XCTUnwrap(app.selectedProfile)
        var changed = original; changed.options.frontmatter = true
        try store.update(changed, replacing: original)
        app.docxChangeMode = .mark
        XCTAssertThrowsError(try app.updateSelectedProfile()); XCTAssertThrowsError(try app.deleteSelectedProfile())
        XCTAssertEqual(try store.load(named: "Original"), changed)
        XCTAssertThrowsError(try app.profileInvocation().verify())
        let changedAfterRestart = model()
        XCTAssertTrue(changedAfterRestart.profileNeedsReload)
        XCTAssertThrowsError(try changedAfterRestart.profileInvocation().verify())
        XCTAssertThrowsError(try changedAfterRestart.deleteSelectedProfile())
        XCTAssertEqual(try store.load(named: "Original"), changed)
        app.refreshProfiles(); XCTAssertNotNil(app.profileMessage)
        try app.selectProfile(named: "Original"); XCTAssertTrue(app.frontmatter)
        try store.delete(changed)
        let restored = model(); XCTAssertEqual(restored.selectedProfileName, "Original"); XCTAssertTrue(restored.frontmatter)
        XCTAssertThrowsError(try restored.profileInvocation().verify())
        try restored.selectProfile(named: nil); XCTAssertTrue(restored.frontmatter)
        XCTAssertNoThrow(try restored.profileInvocation().verify())
    }
    func testLocalProfilesRequirePermissionAndRetainExactDestinationWhenDuplicated() throws {
        let destination = root.appendingPathComponent("exact")
        let profile = try ConversionProfile(name: "Local", outputDirectory: destination, allowLocalTargets: true)
        try store.save(profile, allowLocalTargets: true)
        let app = model(); XCTAssertThrowsError(try app.selectProfile(named: "Local"))
        try app.selectProfile(named: "Local", allowLocalTargets: true)
        XCTAssertTrue(app.usesExactProfileDestination)
        XCTAssertEqual(app.request(for: try csv(), options: app.conversionOptions).destination, .directory(destination))
        XCTAssertThrowsError(try app.profileInvocation().validateBatch())
        try app.saveProfile(named: "Local copy", duplicateSelected: true)
        XCTAssertEqual(try store.load(named: "Local copy").localTargets, profile.localTargets)
        let restored = model(); XCTAssertNoThrow(try restored.profileInvocation().verify())
        XCTAssertTrue(restored.usesExactProfileDestination)
    }
    func testDocumentBindingIsAppliedRejectsChangedBytesAndNeverLeaksIntoBatch() async throws {
        let source = try PDFAnnotationFixture.make(in: root)
        let profile = try ConversionProfile(name: "Second page", options: .init(pdfTextRecognition: .disabled, pdfPages: IndexSelection("2")), boundSource: source)
        try store.save(profile)
        let app = model(); try app.selectProfile(named: profile.name)
        app.convert(source); try await wait(app)
        guard case .succeeded(let result) = app.state else { return XCTFail("Expected selected PDF") }
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("BODY\\_TWO")); XCTAssertFalse(text.contains("BODY\\_ONE"))
        let changed = root.appendingPathComponent("changed.pdf"); try (Data(contentsOf: source) + Data("\n%changed\n".utf8)).write(to: changed)
        app.convert(changed); try await wait(app)
        guard case .failed = app.state else { return XCTFail("Changed bytes accepted") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentConverter.defaultOutputDirectory(for: changed).path))
        app.convert([source,changed]); try await wait(app)
        guard case .batchFinished(let items) = app.state else { return XCTFail("Missing batch errors") }
        XCTAssertTrue(items.allSatisfy { $0.result == nil })
        try app.clearProfileDocumentBinding()
        app.convert(changed); try await wait(app)
        guard case .succeeded(let full) = app.state else { return XCTFail("Binding not cleared") }
        XCTAssertTrue(try String(contentsOf: full.markdownFile, encoding: .utf8).contains("BODY\\_ONE"))
        XCTAssertNotNil(try store.load(named: profile.name).documentBinding)
    }
    func testRunningConversionKeepsItsInitialProfileOptions() async throws {
        let source = try csv(), app = model()
        app.spreadsheetRendering = .tabSeparated; app.conversionReport = true
        try app.saveProfile(named: "Frozen")
        app.convert(source)
        app.spreadsheetRendering = .markdownTable; app.frontmatter = true
        XCTAssertThrowsError(try app.updateSelectedProfile())
        try await wait(app)
        guard case .succeeded(let result) = app.state else { return XCTFail("No result") }
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("PROFILEBODY\t42")); XCTAssertFalse(text.hasPrefix("---"))
        let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: result.outputDirectory.appendingPathComponent("conversion-report.json")))
        XCTAssertEqual(report.options.spreadsheetRendering, .tabSeparated); XCTAssertFalse(report.options.frontmatter)
    }
    func testExplicitPresentationSelectionOverridesProfileNotesPreference() throws {
        let source = root.appendingPathComponent("selection.pptx")
        try PresentationLinkFixture.data(ext: "pptx").write(to: source)
        try store.save(ConversionProfile(name: "No notes", options: .init(presentationIncludeNotes: false)))
        let app = model(); try app.selectProfile(named: "No notes")
        let selection = DocumentContentSelection.presentation(.init(slides: try IndexSelection("1"), includeNotes: true))
        let request = ConversionRequest(inputURL: source, destination: .directory(root.appendingPathComponent("selected")), options: selection.applying(to: app.conversionOptions))
        let prepared = try app.profileInvocation().prepare(request, cancellation: .init())
        XCTAssertTrue(try XCTUnwrap(prepared.options.presentationSelection).includeNotes)
        let result = try DocumentConverter().convert(prepared)
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("NOTE\\_WEB"))
    }
    func testIntentInheritsProfileAndExplicitFalseOverridesIt() async throws {
        let source = try csv()
        try store.save(ConversionProfile(name: "Portable", options: .init(spreadsheetRendering: .tabSeparated, frontmatter: true, outputLayout: .textbundle, sourceMapping: true, conversionReport: true)))
        for override in [false,true] {
            let parent = root.appendingPathComponent(override ? "overridden" : "inherited")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            var intent = ConvertDocumentIntent(); intent.profileStoreOverride = store
            intent.profile = ShortcutProfile(name: "Portable")
            intent.document = IntentFile(fileURL: source); intent.destinationFolder = IntentFile(fileURL: parent)
            if override { intent.textbundle = false; intent.frontmatter = false; intent.conversionReport = false; intent.sourceMapping = false; intent.spreadsheetFormat = .table }
            let value = try await intent.perform(); let output = try XCTUnwrap(URL(string: XCTUnwrap(value.value?.first)))
            XCTAssertEqual(output.lastPathComponent, override ? "values-markdown" : "values.textbundle")
            let text = try String(contentsOf: output.appendingPathComponent(override ? "values.md" : "text.md"), encoding: .utf8)
            XCTAssertFalse(text.hasPrefix("---"))
            if !override {
                let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: output.appendingPathComponent("conversion-report.json")))
                XCTAssertTrue(report.options.frontmatter)
                XCTAssertTrue(try XCTUnwrap(value.value).contains { $0.contains("no frontmatter was written") })
            }
            XCTAssertTrue(text.contains(override ? "| PROFILEBODY | 42 |" : "PROFILEBODY\t42"))
            XCTAssertEqual(FileManager.default.fileExists(atPath: output.appendingPathComponent("conversion-report.json").path), !override)
        }
    }
    func testProfileActionPreservesDefaultsAndExplicitOverridesInRealOutput() async throws {
        let source = try csv(), original = try Data(contentsOf: source)
        try store.save(ConversionProfile(name: "Native defaults", options: .init(
            spreadsheetRendering: .tabSeparated, imageTextRecognition: .disabled,
            frontmatter: true, outputLayout: .textbundle, pdfRemoveHeadersFooters: true,
            pdfDehyphenate: true, sourceMapping: true, conversionReport: true)))
        for override in [false, true] {
            let parent = root.appendingPathComponent(override ? "native-overridden" : "native-inherited")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            var intent = ConvertWithProfileIntent(); intent.profileStoreOverride = store
            intent.profile = ShortcutProfile(name: "Native defaults")
            intent.document = IntentFile(fileURL: source); intent.destinationFolder = IntentFile(fileURL: parent)
            if override {
                intent.textbundle = .disabled; intent.frontmatter = .disabled
                intent.sourceMapping = .disabled; intent.imageOCR = .enabled
                intent.removeHeadersFooters = .disabled; intent.dehyphenate = .disabled
                intent.spreadsheetFormat = .table
            }
            let result = try await intent.perform()
            let output = try XCTUnwrap(URL(string: XCTUnwrap(result.value?.first)))
            XCTAssertEqual(output.lastPathComponent, override ? "values-markdown" : "values.textbundle")
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: output.appendingPathComponent("conversion-report.json")))
            XCTAssertEqual(report.options.frontmatter, !override)
            XCTAssertTrue(report.options.sourceMapping) // Berichte aktivieren ihre erforderliche Quellzuordnung unabhängig vom Schalter.
            XCTAssertEqual(report.options.pdfRemoveHeadersFooters, !override)
            XCTAssertEqual(report.options.pdfDehyphenate, !override)
            XCTAssertEqual(report.options.imageTextRecognition, override ? .enabled : .disabled)
            let text = try String(contentsOf: output.appendingPathComponent(override ? "values.md" : "text.md"), encoding: .utf8)
            XCTAssertTrue(text.contains(override ? "| PROFILEBODY | 42 |" : "PROFILEBODY\t42"))
        }
        let parent = root.appendingPathComponent("native-no-report")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        var intent = ConvertWithProfileIntent(); intent.profileStoreOverride = store
        intent.profile = ShortcutProfile(name: "Native defaults")
        intent.document = IntentFile(fileURL: source); intent.destinationFolder = IntentFile(fileURL: parent)
        intent.conversionReport = .disabled
        let result = try await intent.perform()
        let output = try XCTUnwrap(URL(string: XCTUnwrap(result.value?.first)))
        XCTAssertEqual(output.lastPathComponent, "values.textbundle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("conversion-report.json").path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testIntentBindingMissingProfileAndLocalPermissionFailBeforeOutput() async throws {
        let source = try PDFAnnotationFixture.make(in: root), parent = root.appendingPathComponent("intent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try store.save(ConversionProfile(name: "Bound", options: .init(pdfTextRecognition: .disabled, pdfPages: IndexSelection("2")), boundSource: source))
        var intent = ConvertWithProfileIntent(); intent.profileStoreOverride = store
        intent.profile = ShortcutProfile(name: "Bound"); intent.document = IntentFile(fileURL: source); intent.destinationFolder = IntentFile(fileURL: parent)
        let value = try await intent.perform(); let output = try XCTUnwrap(URL(string: XCTUnwrap(value.value?.first)))
        XCTAssertFalse(try String(contentsOf: output.appendingPathComponent("review.md"), encoding: .utf8).contains("BODY\\_ONE"))
        intent.profile = ShortcutProfile(name: "Missing")
        do { _ = try await intent.perform(); XCTFail("Missing profile accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("profile")) }
        try store.save(ConversionProfile(name: "Local", outputDirectory: root.appendingPathComponent("local"), allowLocalTargets: true), allowLocalTargets: true)
        intent.profile = ShortcutProfile(name: "Local")
        do { _ = try await intent.perform(); XCTFail("Local profile accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("local paths")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["review-markdown"])
    }
    func testRealAppIntentAndCLIMatrixHasIdenticalOptionsContentAndAssets() async throws {
        let pdf = try PDFAnnotationFixture.make(in: root), docx = try DOCXReviewFixture.make(in: root), csv = try csv()
        let pptx = root.appendingPathComponent("links.pptx"); try PresentationLinkFixture.data(ext: "pptx").write(to: pptx)
        let profile = try ConversionProfile(name: "Acceptance Matrix", options: .init(spreadsheetRendering: .tabSeparated, imageTextRecognition: .disabled, frontmatter: true, outputLayout: .textbundle, pdfTextRecognition: .disabled, docxChangeMode: .mark, pdfLayout: .legacy, presentationIncludeNotes: false, sourceMapping: true, conversionReport: true))
        try store.save(profile)
        let export = ProcessInfo.processInfo.environment["PMT_APP_PROFILE_MATRIX_DIR"].map { URL(fileURLWithPath: $0) }
        if let export {
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
            try ConversionProfileStore.export(profile, to: export.appendingPathComponent("profile.json"))
            try PresentationLinkFixture.image.write(to: export.appendingPathComponent("reference.png"))
            let sources = export.appendingPathComponent("sources"); try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
            for source in [pdf,csv,pptx,docx] { try FileManager.default.copyItem(at: source, to: sources.appendingPathComponent(source.lastPathComponent)) }
        }
        var receipts: [[String: Any]] = []
        for source in [pdf,csv,pptx,docx] {
            let original = try Data(contentsOf: source), format = source.pathExtension
            var markdown: [Data] = [], reports: [ConversionReport] = []
            for entry in ["app","intent","cli"] {
                let parent = root.appendingPathComponent(entry + "-" + format)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                let output: URL
                if entry == "app" {
                    let app = model(); try app.selectProfile(named: profile.name); app.destinationFolder = parent
                    app.convert(source); try await wait(app)
                    guard case .succeeded(let result) = app.state else { return XCTFail("App profile conversion failed") }
                    output = result.outputDirectory
                } else if entry == "intent" {
                    var intent = ConvertDocumentIntent(); intent.profileStoreOverride = store
                    intent.profile = ShortcutProfile(name: profile.name); intent.document = IntentFile(fileURL: source); intent.destinationFolder = IntentFile(fileURL: parent)
                    let result = try await intent.perform(); output = try XCTUnwrap(URL(string: XCTUnwrap(result.value?.first)))
                } else {
                    output = parent.appendingPathComponent(DocumentConverter.outputDirectoryName(for: source, layout: .textbundle))
                    let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("poormans-text")
                    let result = try ProcessRunner.run(executable: cli, arguments: ["--profiles-directory",store.directory.path,"--profile",profile.name,"--json","-o",output.path,source.path], currentDirectory: root, captureStandardOutput: true, timeout: 30)
                    XCTAssertEqual(result.status,0,result.standardOutput + result.standardError)
                }
                let data = try Data(contentsOf: output.appendingPathComponent("text.md")); markdown.append(data)
                let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: output.appendingPathComponent("conversion-report.json"))); reports.append(report)
                XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
                var plain = ""
                func visit(_ node: any Markup) {
                    if let text = node as? Markdown.Text { plain += text.string + " " }
                    if let block = node as? CodeBlock { plain += block.code + " " }
                    if let code = node as? InlineCode { plain += code.code + " " }
                    for child in node.children { visit(child) }
                }
                visit(Document(parsing: String(decoding: data,as: UTF8.self).components(separatedBy: "## Document comments")[0]))
                let token = format == "csv" ? "PROFILEBODY" : format == "pdf" ? "BODY_TWO" : format == "pptx" ? "BODYTWO" : "INSERTONLY"
                XCTAssertEqual(plain.components(separatedBy: token).count - 1,1,plain)
                if format == "pptx" { XCTAssertFalse(plain.contains("NOTE_WEB")); XCTAssertFalse(plain.contains("NOTE_JUMP")) }
                let imageFiles = report.outputs.filter { $0.path.hasSuffix(".png") }
                XCTAssertEqual(imageFiles.count,["pptx","docx"].contains(format) ? 1 : 0)
                for image in imageFiles { XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(image.path)),try PresentationLinkFixture.image) }
                XCTAssertEqual(try Data(contentsOf: source),original)
                if let export { try FileManager.default.copyItem(at: output,to: export.appendingPathComponent(entry + "-" + format + ".textbundle")) }
            }
            XCTAssertEqual(markdown[0],markdown[1]); XCTAssertEqual(markdown[0],markdown[2])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(reports[0].options),try encoder.encode(reports[1].options))
            XCTAssertEqual(try encoder.encode(reports[0].options),try encoder.encode(reports[2].options))
            XCTAssertEqual(reports[0].outputs,reports[1].outputs); XCTAssertEqual(reports[0].outputs,reports[2].outputs)
            receipts.append(["format":format,"entries":["app","intent","cli"],"markdownSHA256":ConversionFileFingerprint.digest(markdown[0]),"sourceSHA256":ConversionFileFingerprint.digest(original),"independentBodyTokenCount":1,"optionsAndManifestEqual":true])
        }
        if let export { try JSONSerialization.data(withJSONObject: receipts,options: [.prettyPrinted,.sortedKeys]).write(to: export.appendingPathComponent("matrix.json")) }
    }
}
