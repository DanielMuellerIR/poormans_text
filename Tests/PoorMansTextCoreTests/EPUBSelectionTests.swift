import Foundation
import XCTest
@testable import PoorMansTextCore

final class EPUBSelectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTEPUBSelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testOverviewUsesSpineOrderIncludesNavigationFragmentsAndPreservesSource() throws {
        let source = try EPUBSelectionFixture.create(in: root)
        let original = try Data(contentsOf: source)
        let summary = try DocumentConverter().inspectEPUBContents(source, maximumChapters: 2)
        XCTAssertEqual(summary.chapterCount, 3)
        XCTAssertEqual(summary.chapters.map(\.number), [1, 2]); XCTAssertEqual(summary.chapters.map(\.title), ["BetaMarker", "AlphaMarker"])
        XCTAssertEqual(summary.chapters.map(\.path), ["OEBPS/b/ch.xhtml", "OEBPS/a/ch.xhtml"])
        XCTAssertTrue(summary.chaptersTruncated)
        XCTAssertEqual(summary.navigation.map(\.chapter), [2, 1, 1, 3])
        XCTAssertEqual(summary.navigation.map(\.fragment), ["target", "target", "detail", "target"])
        XCTAssertTrue(try summary.sourceIdentity.matchesFile(at: source))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["selection.epub"])
    }

    func testSelectedChaptersKeepSourceNumbersLinksImagesAndRangesInBothLayouts() throws {
        let source = try EPUBSelectionFixture.create(in: root)
        let original = try Data(contentsOf: source)
        for layout in [OutputLayout.markdownFolder, .textbundle] {
            let destination = root.appendingPathComponent(UUID().uuidString + (layout == .textbundle ? ".textbundle" : ""))
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(frontmatter: true, outputLayout: layout, epubChapters: IndexSelection("3,1,1"), conversionReport: true)))
            let data = try Data(contentsOf: result.markdownFile), text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(text.components(separatedBy: "BetaMarker").count - 1, 1)
            XCTAssertEqual(text.components(separatedBy: "GammaMarker").count - 1, 1)
            XCTAssertFalse(text.contains("AlphaMarker")); XCTAssertFalse(text.contains("PMTEPUB"))
            XCTAssertTrue(text.contains("[To gamma](#pmt-epub-chapter-3-anchor-"), text)
            XCTAssertTrue(text.contains("[To beta](#pmt-epub-chapter-1-anchor-"), text)
            XCTAssertFalse(text.contains("[To alpha](")); XCTAssertTrue(text.contains("To alpha"))
            XCTAssertTrue(result.diagnostics.contains { $0.code == "epub.linkTargetExcluded" && $0.location?.chapter == 1 && $0.kind == .information })
            XCTAssertEqual(result.assets.count, 1)
            XCTAssertEqual(try Data(contentsOf: result.assets[0]), try EPUBSelectionFixture.png())
            XCTAssertEqual(result.sourceMappings.map { $0.source.chapter }, [1, 3])
            for (mapping, marker) in zip(result.sourceMappings, ["BetaMarker", "GammaMarker"]) {
                XCTAssertTrue(mapping.output.text(in: data)?.contains(marker) == true)
                XCTAssertTrue(mapping.output.text(in: data)?.contains("<a id=\"pmt-epub-chapter-") == true)
            }
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
            XCTAssertEqual(report.options.epubChapters?.description, "1,3")
            XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testSelectedAuxiliaryChapterIsExplicitWhileDefaultKeepsNativeReadingOrder() throws {
        let source = try EPUBSelectionFixture.create(in: root, auxiliary: true)
        let summary = try DocumentConverter().inspectEPUBContents(source)
        XCTAssertEqual(summary.chapters.map(\.isLinear), [true, true, false])
        let normal = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("normal"))))
        XCTAssertFalse(try String(contentsOf: normal.markdownFile, encoding: .utf8).contains("GammaMarker"))
        let selected = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("auxiliary")), options: .init(epubChapters: IndexSelection("3"))))
        XCTAssertTrue(try String(contentsOf: selected.markdownFile, encoding: .utf8).contains("GammaMarker"))
    }

    func testBrokenNavigationFallsBackToSpineWithDiagnosticAndRetainedText() throws {
        let source = try EPUBSelectionFixture.create(in: root, brokenNavigation: true)
        let summary = try DocumentConverter().inspectEPUBContents(source)
        XCTAssertEqual(summary.chapterCount, 3); XCTAssertTrue(summary.navigation.isEmpty)
        XCTAssertTrue(summary.diagnostics.contains { $0.code == "epub.navigationUnavailable" })
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(epubChapters: IndexSelection("2"))))
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("AlphaMarker"))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "epub.navigationUnavailable" })
    }

    func testMissingNavigationTargetsAreDiagnosedWithoutDroppingChapters() throws {
        let source = try EPUBSelectionFixture.create(in: root, variant: "missing-nav-target")
        let summary = try DocumentConverter().inspectEPUBContents(source)
        XCTAssertEqual(summary.chapters.count, 3)
        XCTAssertTrue(summary.diagnostics.contains { $0.code == "epub.navigationTargetUnavailable" })
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(epubChapters: IndexSelection("2"))))
        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("AlphaMarker"))
    }

    func testMissingFragmentsUnsafeLinksAndCodeExamplesRemainUnderstandable() throws {
        let source = try EPUBSelectionFixture.create(in: root)
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(epubChapters: IndexSelection("1-3"), conversionReport: true)))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("Missing target")); XCTAssertFalse(text.contains("[Missing target]("))
        XCTAssertTrue(text.contains("Unsafe target")); XCTAssertFalse(text.contains("javascript:"))
        XCTAssertTrue(text.contains("[literal](literal.png)"))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "epub.linkTargetUnavailable" && $0.location?.chapter == 2 })
        XCTAssertFalse(text.contains("PMTEPUB"))
    }

    func testRepeatedSpineDocumentsAndDuplicateFragmentIDsAreControlled() throws {
        for variant in ["repeated", "duplicate-id"] {
            let source = try EPUBSelectionFixture.create(in: root, name: variant, variant: variant)
            let destination = root.appendingPathComponent(variant + "-never")
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(epubChapters: IndexSelection("1")))))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testSelectionCannotBypassZIPOrXMLSafety() throws {
        for variant in ["corrupt-unused", "entity", "too-many"] {
            let source = try EPUBSelectionFixture.create(in: root, name: variant, variant: variant)
            let destination = root.appendingPathComponent(variant + "-never")
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(epubChapters: IndexSelection("1")))))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testOverviewTitleAndLimitsAreBoundedAndWrongFormatsAreRejected() throws {
        let source = try EPUBSelectionFixture.create(in: root, variant: "long-title")
        let summary = try DocumentConverter().inspectEPUBContents(source, maximumChapters: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(summary.chapters[0].title).utf8.count, 256)
        XCTAssertFalse(summary.chapters[0].title!.contains("�"))
        for count in [0, 501] { XCTAssertThrowsError(try DocumentConverter().inspectEPUBContents(source, maximumChapters: count)) }
        let csv = root.appendingPathComponent("values.csv"); try Data("Name,Value\nMarker,1\n".utf8).write(to: csv)
        XCTAssertThrowsError(try DocumentConverter().inspectEPUBContents(csv))
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: csv, options: .init(epubChapters: IndexSelection("1")))))
    }

    func testSelectedProgressAndDiagnosticCapsRemainAccurate() throws {
        let source = try EPUBSelectionFixture.create(in: root, variant: "many-links")
        let progress = ProgressValues()
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(epubChapters: IndexSelection("1"), sourceMapping: true)), progress: { if $0.unit == .chapter { progress.append($0) } })
        XCTAssertEqual(progress.snapshot.map(\.completed), [0, 1]); XCTAssertEqual(progress.snapshot.map(\.total), [1, 1])
        let omitted = try XCTUnwrap(result.diagnostics.first { $0.code == "diagnostics.limited" })
        XCTAssertEqual(omitted.omittedCount, 46)
        XCTAssertEqual(result.sourceMappings.map { $0.source.chapter }, [1])
    }

    private final class ProgressValues: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [ConversionProgress]()
        func append(_ value: ConversionProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var snapshot: [ConversionProgress] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testCancellationAndOutOfBoundsSelectionLeaveNoPublishedOutput() throws {
        let source = try EPUBSelectionFixture.create(in: root), destination = root.appendingPathComponent("never")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(epubChapters: IndexSelection("4")))))
        let token = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(epubChapters: IndexSelection("1,3"))), progress: { if $0.unit == .chapter { token.cancel() } }, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try DocumentConverter().inspectEPUBContents(source, cancellation: token))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
    }
}

enum EPUBSelectionFixture {
    static func png() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/WordProcessing/fixture.png"))
    }
    static func create(in root: URL, name: String = "selection", auxiliary: Bool = false, brokenNavigation: Bool = false, variant: String = "") throws -> URL {
        let container = "<container xmlns=\"\(EPUBMetadataReader.containerNamespace)\"><rootfiles><rootfile full-path=\"OEBPS/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
        let spine = variant == "too-many" ? String(repeating: "<itemref idref=\"beta\"/>", count: 1_001) : "<itemref idref=\"beta\"/><itemref idref=\"\(variant == "repeated" ? "beta" : "alpha")\"/><itemref idref=\"gamma\"\(auxiliary ? " linear=\"no\"" : "")/>"
        let opf = """
        <package xmlns="\(EPUBSelectionPackage.opf)" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">selection</dc:identifier><dc:title>EPUB proof</dc:title><dc:language>en</dc:language></metadata><manifest>
        <item id="alpha" href="a/ch.xhtml" media-type="application/xhtml+xml"/><item id="beta" href="b/ch.xhtml" media-type="application/xhtml+xml"/><item id="gamma" href="gamma.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="image" href="picture.png" media-type="image/png"/>
        </manifest><spine>\(spine)</spine></package>
        """
        var nav = brokenNavigation ? "<html><broken" : "<html xmlns=\"\(EPUBSelectionPackage.xhtml)\"><body><nav><a href=\"a/ch.xhtml#target\">Alpha</a><a href=\"b/ch.xhtml#target\">Beta</a><a href=\"b/ch.xhtml#detail\">Beta section</a><a href=\"gamma.xhtml#target\">Gamma</a></nav></body></html>"
        if variant == "missing-nav-target" { nav = nav.replacingOccurrences(of: "a/ch.xhtml#target", with: "missing.xhtml#target") }
        func chapter(_ marker: String, prefix: String, links: String) -> String {
            "<html xmlns=\"\(EPUBSelectionPackage.xhtml)\"><head><title>\(marker)</title></head><body><h1 id=\"target\">\(marker)</h1><p id=\"detail\">Detail text</p>\(links)<p><img src=\"\(prefix)picture.png\" alt=\"Picture\"/></p><pre><code>[literal](literal.png)</code></pre></body></html>"
        }
        var alpha = chapter("AlphaMarker", prefix: "../", links: "<p><a href=\"#missing\">Missing target</a></p><p><a href=\"javascript:bad()\">Unsafe target</a></p>")
        var beta = chapter(variant == "long-title" ? String(repeating: "Beta🙂", count: 100) : "BetaMarker", prefix: "../", links: "<p><a href=\"../gamma.xhtml#target\">To gamma</a></p><p><a href=\"../a/ch.xhtml#target\">To alpha</a></p>")
        if variant == "many-links" { beta = beta.replacingOccurrences(of: "</body>", with: (1...300).map { "<p><a href=\"missing\($0).xhtml\">Missing \($0)</a></p>" }.joined() + "</body>") }
        if variant == "duplicate-id" { beta = beta.replacingOccurrences(of: "</body>", with: "<p id=\"target\">Duplicate</p></body>") }
        if variant == "entity" { beta = "<!DOCTYPE html [<!ENTITY secret SYSTEM 'file:///never-read'>]>" + beta }
        if variant == "long-title" { alpha = alpha.replacingOccurrences(of: "AlphaMarker", with: "Alpha") }
        let gamma = chapter("GammaMarker", prefix: "", links: "<p><a href=\"b/ch.xhtml#target\">To beta</a></p>")
        var entries: [ZIPFixtureBuilder.Entry] = [.init(name: "mimetype", content: Data("application/epub+zip".utf8), isStored: true), .init(name: "META-INF/container.xml", content: Data(container.utf8)), .init(name: "OEBPS/package.opf", content: Data(opf.utf8)), .init(name: "OEBPS/a/ch.xhtml", content: Data(alpha.utf8)), .init(name: "OEBPS/b/ch.xhtml", content: Data(beta.utf8)), .init(name: "OEBPS/gamma.xhtml", content: Data(gamma.utf8)), .init(name: "OEBPS/nav.xhtml", content: Data(nav.utf8)), .init(name: "OEBPS/picture.png", content: try png())]
        if variant == "corrupt-unused" { entries.append(.init(name: "unused.bin", content: Data([1, 2, 3]), declaredChecksum: 0)) }
        let source = root.appendingPathComponent(name + ".epub")
        try ZIPFixtureBuilder.archive(entries: [entries[0]] + Array(entries.dropFirst().reversed())).write(to: source)
        return source
    }
}
