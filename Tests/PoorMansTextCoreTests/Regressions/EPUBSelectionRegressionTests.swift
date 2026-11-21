import Foundation
import XCTest
@testable import PoorMansTextCore

final class EPUBSelectionRegressionTests: XCTestCase {
    func testNumericEPUBFragmentsKeepTheirTextLinksAndAsset() throws {
        let root = try makeRegressionDirectory()
        let source = root.appendingPathComponent("numbers.epub")
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Numeric chapter</title></head><body><h1>Numeric chapter</h1><p><span id="number">123</span> and <span id="year">2026</span></p><p><a href="#number">Number link</a> and <a href="#year">Year link</a></p><p><img src="picture.png" alt="Picture"/></p></body></html>
        """
        let entries: [ZIPFixtureBuilder.Entry] = [
            .init(name: "mimetype", content: Data("application/epub+zip".utf8), isStored: true),
            .init(name: "META-INF/container.xml", content: Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)),
            .init(name: "package.opf", content: Data("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Numeric chapter</dc:title></metadata><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"image\" href=\"picture.png\" media-type=\"image/png\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>".utf8)),
            .init(name: "chapter.xhtml", content: Data(xhtml.utf8)),
            .init(name: "picture.png", content: try RegressionFixtures.png())
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
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.assets.first)), try RegressionFixtures.png())
            XCTAssertEqual(result.sourceMappings.map(\.source.chapter), [1])
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }
}
