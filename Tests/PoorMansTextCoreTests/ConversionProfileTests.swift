import Foundation
import XCTest
@testable import PoorMansTextCore

final class ConversionProfileTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTProfiles-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func testKnownSchemaDefaultsAndCompletePortableRoundtrip() throws {
        let defaults = try ConversionProfile.decode(Data(#"{"schemaVersion":1,"name":"Default","options":{}}"#.utf8))
        XCTAssertEqual(defaults.options.conversionOptions, .init()); XCTAssertEqual(defaults.scope,"portable")
        let options = ConversionOptions(spreadsheetRendering: .tabSeparated,imageTextRecognition: .disabled,frontmatter: true,outputLayout: .textbundle,pdfTextRecognition: .disabled,ocrLanguages: ["en"],ocrMethod: .structured,docxChangeMode: .mark,pdfLayout: .legacy,pdfRemoveHeadersFooters: true,pdfDehyphenate: true,presentationIncludeNotes: false,sourceMapping: true,conversionReport: true)
        let profile = try ConversionProfile(name: "Übertragung",options: options), data = try profile.encoded()
        XCTAssertEqual(try ConversionProfile.decode(data),profile)
        XCTAssertEqual(try profile.resolve().options,options)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys),["schemaVersion","name","options"])
        XCTAssertFalse(String(decoding: data,as: UTF8.self).contains(root.path))
    }
    func testUnknownVersionsFieldsDuplicatesInvalidValuesAndBudgetsAreRejected() throws {
        for text in [
            #"{"schemaVersion":2,"name":"Future","options":{}}"#,
            #"{"schemaVersion":1,"name":"Unknown","secret":"ignored","options":{}}"#,
            #"{"schemaVersion":1,"name":"Unknown","options":{"typo":true}}"#,
            #"{"schemaVersion":1,"name":"Duplicate","options":{"frontmatter":true,"frontmatter":false}}"#,
            #"{"schemaVersion":1,"name":"Duplicate","options":{"frontmatter":true,"\u0066rontmatter":false}}"#,
            #"{"schemaVersion":1,"name":"Bad","options":{"ocrMethod":"cloud"}}"#,
            #"{"schemaVersion":1,"name":"Bad","options":{"frontmatter":null}}"#,
            #"{"schemaVersion":1,"name":"Bad","options":{"ocrLanguages":["not-a-language"]}}"#,
            #"{"schemaVersion":1,"name":"../path","options":{}}"#,
            #"{"schemaVersion":1,"name":"A\u0085B","options":{}}"#,
            #"{"schemaVersion":1,"name":"A\u2028B","options":{}}"#,
            #"{"schemaVersion":1,"name":"Bad","options":{},"localTargets":{"outputDirectory":"relative"}}"#,
            String(repeating: "[",count: 18) + "0" + String(repeating: "]",count: 18), "{"
        ] { XCTAssertThrowsError(try ConversionProfile.decode(Data(text.utf8)),text) }
        XCTAssertThrowsError(try ConversionProfile.decode(Data(repeating: 32,count: ConversionProfile.maximumBytes + 1)))
        var profile = try ConversionProfile(name: "Valid"); profile.options.ocrLanguages = Array(repeating: "en",count: 33)
        XCTAssertThrowsError(try profile.encoded())
    }
    func testStoreRoundtripCaseAndUnicodeCollisionsAndExportAreAtomic() throws {
        let store = ConversionProfileStore(directory: root.appendingPathComponent("profiles"))
        XCTAssertEqual(try store.profiles(),[])
        let profile = try ConversionProfile(name: "Grüße")
        try store.save(profile)
        XCTAssertEqual(try store.load(named: "GRÜSSE"),profile)
        XCTAssertThrowsError(try store.save(ConversionProfile(name: "GRÜSSE")))
        let composed = try ConversionProfile(name: "Café"), decomposed = try ConversionProfile(name: "Cafe\u{301}")
        try store.save(composed); XCTAssertThrowsError(try store.save(decomposed))
        XCTAssertEqual(try store.profiles().count,2)
        let path = root.appendingPathComponent("export.json")
        try ConversionProfileStore.export(profile,to: path)
        let original = try Data(contentsOf: path)
        XCTAssertEqual(try ConversionProfileStore.readProfile(at: path),profile)
        XCTAssertThrowsError(try ConversionProfileStore.export(composed,to: path))
        XCTAssertEqual(try Data(contentsOf: path),original)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link,withDestinationURL: path)
        XCTAssertThrowsError(try ConversionProfileStore.export(composed,to: link))
        XCTAssertEqual(try Data(contentsOf: path),original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".profile-") })
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testLocalTargetsRequirePermissionForCaptureSaveExportAndResolve() throws {
        let target = root.appendingPathComponent("result"), tool = root.appendingPathComponent("pandoc")
        XCTAssertThrowsError(try ConversionProfile(name: "Local",options: .init(pandocExecutable: tool),outputDirectory: target))
        let profile = try ConversionProfile(name: "Local",options: .init(pandocExecutable: tool),outputDirectory: target,allowLocalTargets: true)
        XCTAssertEqual(profile.scope,"local")
        XCTAssertThrowsError(try profile.resolve())
        let resolved = try profile.resolve(allowLocalTargets: true)
        XCTAssertEqual(resolved.outputDirectory,target); XCTAssertEqual(resolved.options.pandocExecutable,tool)
        let store = ConversionProfileStore(directory: root.appendingPathComponent("profiles"))
        XCTAssertThrowsError(try store.save(profile)); try store.save(profile,allowLocalTargets: true)
        XCTAssertThrowsError(try ConversionProfileStore.export(profile,to: root.appendingPathComponent("forbidden.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden.json").path))
    }
    func testBoundPDFSelectionRequiresExactBytesAndCanBeClearedExplicitly() throws {
        let source = try PDFAnnotationFixture.make(in: root), original = try Data(contentsOf: source)
        let options = ConversionOptions(pdfTextRecognition: .disabled,pdfPages: try IndexSelection("2"))
        XCTAssertThrowsError(try ConversionProfile(name: "Selection",options: options))
        XCTAssertThrowsError(try ConversionProfile(name: "Outside",options: .init(pdfPages: IndexSelection("999")),boundSource: source))
        let profile = try ConversionProfile(name: "Selection",options: options,boundSource: source)
        let roundtrip = try ConversionProfile.decode(profile.encoded())
        XCTAssertEqual(roundtrip,profile); XCTAssertEqual(profile.scope,"documentBound")
        let resolved = try profile.resolve(for: source)
        let result = try DocumentConverter().convert(.init(inputURL: source,destination: .directory(root.appendingPathComponent("selected")),options: resolved.options,expectedSourceIdentity: resolved.expectedSourceIdentity))
        let text = try String(contentsOf: result.markdownFile,encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "BODY\\_TWO").count - 1,1)
        XCTAssertFalse(text.contains("BODY\\_ONE")); XCTAssertFalse(text.contains("COMMENT"))
        let changed = root.appendingPathComponent("copy.pdf"); try (original + Data("\n%changed\n".utf8)).write(to: changed)
        XCTAssertThrowsError(try profile.resolve(for: changed))
        let cleared = try profile.resolve(for: changed,discardBoundSelection: true)
        XCTAssertNil(cleared.expectedSourceIdentity); XCTAssertNil(cleared.options.pdfPages)
        XCTAssertFalse(String(decoding: try profile.encoded(),as: UTF8.self).contains(source.path))
        XCTAssertEqual(try Data(contentsOf: source),original)
        let cancelled = ConversionCancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try ConversionProfile(name: "Cancelled",options: options,boundSource: source,cancellation: cancelled)) { error in guard case ConversionError.cancelled = error else { return XCTFail("\(error)") } }
        XCTAssertThrowsError(try profile.resolve(for: source,cancellation: cancelled)) { error in guard case ConversionError.cancelled = error else { return XCTFail("\(error)") } }
    }
    func testBoundSourceChangedDuringConversionCannotPublish() throws {
        let source = try PDFAnnotationFixture.make(in: root), original = try Data(contentsOf: source)
        let profile = try ConversionProfile(name: "Bound",options: .init(pdfTextRecognition: .disabled,pdfPages: IndexSelection("2")),boundSource: source)
        let resolved = try profile.resolve(for: source), output = root.appendingPathComponent("never")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source,destination: .directory(output),options: resolved.options,expectedSourceIdentity: resolved.expectedSourceIdentity),progress: { progress in
            if progress.phase == .converting && progress.unit == nil { try? (original + Data("\n%replacement\n".utf8)).write(to: source,options: .atomic) }
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testFieldOverridesRetainOtherProfileValuesAndNotesArePortable() throws {
        let base = try ConversionProfile(name: "Base",options: .init(spreadsheetRendering: .tabSeparated,frontmatter: true,outputLayout: .textbundle,docxChangeMode: .mark,presentationIncludeNotes: false))
        let resolved = try base.resolve(overriding: .init(frontmatter: false,outputLayout: .markdownFolder),explicit: [.frontmatter,.outputLayout])
        XCTAssertFalse(resolved.options.frontmatter); XCTAssertEqual(resolved.options.outputLayout,.markdownFolder)
        XCTAssertEqual(resolved.options.docxChangeMode,.mark); XCTAssertEqual(resolved.options.spreadsheetRendering,.tabSeparated)
        let source = root.appendingPathComponent("links.pptx"); try PresentationLinkFixture.data(ext: "pptx").write(to: source)
        let converted = try DocumentConverter().convert(.init(inputURL: source,destination: .directory(root.appendingPathComponent("slides")),options: resolved.options))
        XCTAssertFalse(try String(contentsOf: converted.markdownFile,encoding: .utf8).contains("NOTE"))
        let csv = root.appendingPathComponent("values.csv"); try Data("Name,Value\nCSV_BODY,42\n".utf8).write(to: csv)
        let other = try DocumentConverter().convert(.init(inputURL: csv,destination: .directory(root.appendingPathComponent("csv")),options: resolved.options))
        XCTAssertTrue(try String(contentsOf: other.markdownFile,encoding: .utf8).contains("CSV_BODY"))
    }
    func testConcurrentNameCollisionNeverOverwritesTheWinner() async throws {
        let directory = root.appendingPathComponent("concurrent"), store = ConversionProfileStore(directory: directory)
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for flag in [false,true] {
                group.addTask {
                    do { try store.save(ConversionProfile(name: "Winner",options: .init(frontmatter: flag))); return "saved" }
                    catch let error as ConversionProfileError { return error.kind == .collision ? "collision" : error.kind == .fileSystem ? "busy" : "unexpected" }
                }
            }
            var results: [String] = []; for try await result in group { results.append(result) }; return results
        }
        XCTAssertEqual(results.filter { $0 == "saved" }.count,1)
        XCTAssertFalse(results.contains("unexpected")); XCTAssertEqual(try store.profiles().count,1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".profile-") })
    }
    func testBoundSpreadsheetEPUBAndSlideSelectionsRoundtripAndOverrideIndependently() throws {
        for source in try SpreadsheetSelectionFixture.create(in: root) {
            let selection = try SpreadsheetSelection(sheets: .names(["Hidden"]),ranges: [SpreadsheetCellRange("B2:C2")])
            let profile = try ConversionProfile(name: source.pathExtension,options: .init(spreadsheetSelection: selection),boundSource: source)
            let decoded = try ConversionProfile.decode(profile.encoded())
            let changed = try decoded.resolve(for: source,overriding: .init(spreadsheetSelection: SpreadsheetSelection(ranges: [SpreadsheetCellRange("D4:E4")])),explicit: [.spreadsheetRanges])
            XCTAssertEqual(changed.options.spreadsheetSelection?.sheets,.names(["Hidden"]))
            XCTAssertEqual(changed.options.spreadsheetSelection?.ranges.map(\.description),["D4:E4"])
            let result = try DocumentConverter().convert(.init(inputURL: source,destination: .directory(root.appendingPathComponent(source.pathExtension + "-selected")),options: changed.options,expectedSourceIdentity: changed.expectedSourceIdentity))
            let text = try String(contentsOf: result.markdownFile,encoding: .utf8)
            XCTAssertTrue(text.contains("2404")); XCTAssertTrue(text.contains("2405")); XCTAssertFalse(text.contains("1404"))
        }
        let epub = try EPUBSelectionFixture.create(in: root)
        let book = try ConversionProfile(name: "Book",options: .init(epubChapters: IndexSelection("2")),boundSource: epub)
        XCTAssertEqual(try ConversionProfile.decode(book.encoded()).resolve(for: epub).options.epubChapters?.description,"2")
        let slides = root.appendingPathComponent("linked.odp");try PresentationLinkFixture.data(ext: "odp").write(to: slides)
        let deck = try ConversionProfile(name: "Deck",options: .init(presentationSelection: .init(slides: IndexSelection("1"),includeNotes: false)),boundSource: slides)
        let changed = try ConversionProfile.decode(deck.encoded()).resolve(for: slides,overriding: .init(presentationIncludeNotes: true),explicit: [.presentationIncludeNotes])
        XCTAssertEqual(changed.options.presentationSelection?.slides?.description,"1"); XCTAssertEqual(changed.options.presentationSelection?.includeNotes,true)
    }
    func testStoreLimitAndCorruptOrSymlinkedEntriesFailSafely() throws {
        let directory = root.appendingPathComponent("profiles"), store = ConversionProfileStore(directory: directory)
        try store.save(ConversionProfile(name: "One"))
        let filename = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.path).first)
        let saved = directory.appendingPathComponent(filename), external = root.appendingPathComponent("external.json")
        try ConversionProfileStore.export(ConversionProfile(name: "External"),to: external)
        try FileManager.default.removeItem(at: saved); try FileManager.default.createSymbolicLink(at: saved,withDestinationURL: external)
        XCTAssertThrowsError(try store.load(named: "One")); XCTAssertThrowsError(try store.profiles())
        try FileManager.default.removeItem(at: saved)
        for index in 0..<256 { try store.save(ConversionProfile(name: "Profile \(index)")) }
        XCTAssertThrowsError(try store.save(ConversionProfile(name: "Overflow")))
        XCTAssertEqual(try store.profiles().count,256)
        let link = root.appendingPathComponent("store-link")
        try FileManager.default.createSymbolicLink(at: link,withDestinationURL: directory)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertThrowsError(try ConversionProfileStore(directory: link).save(ConversionProfile(name: "ThroughLink")))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber,permissions)
    }
}
