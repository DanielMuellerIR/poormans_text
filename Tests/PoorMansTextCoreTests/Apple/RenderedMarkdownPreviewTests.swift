import Foundation
import XCTest
import ImageIO
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class RenderedMarkdownPreviewTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTPreview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var png: Data { get throws { try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png")) } }

    func testMarkdownStructuresRemainLiteralAndRawHTMLCannotBecomeActive() {
        let source = """
        # Heading🙂

        - First
        - **Bold** and *emphasis* with `inline`

        | Name | Value |
        | --- | ---: |
        | Grüße | 42<br>43 |

        ```html
        <script>window.bad=1</script>
        ```

        <script>window.bad=2</script>
        <iframe src="https://example.invalid/"></iframe>

        [Remote](https://example.invalid/) ![Remote image](https://example.invalid/image.png)
        """
        let preview = RenderedMarkdownPreview.render(source, assets: nil)
        XCTAssertTrue(preview.html.contains("<h1"))
        XCTAssertTrue(preview.html.contains("<ul"))
        XCTAssertTrue(preview.html.contains("<table>"))
        XCTAssertTrue(preview.html.contains("<strong"))
        XCTAssertTrue(preview.html.contains("42<br>43"))
        XCTAssertTrue(preview.html.contains("&lt;script&gt;window.bad=2&lt;/script&gt;"))
        XCTAssertFalse(preview.html.contains("<script>"))
        XCTAssertFalse(preview.html.contains("<iframe"))
        XCTAssertFalse(preview.html.contains("href=\"https:"))
        XCTAssertFalse(preview.html.contains("src=\"https:"))
        XCTAssertTrue(preview.hasLiteralHTML)
        XCTAssertEqual(preview.unavailableImageCount, 1)
        XCTAssertTrue(preview.html.contains("default-src 'none'"))
    }

    func testOnlyExactEmptyEPUBAnchorsAreRenderedAndCodeRemainsLiteral() throws {
        let source = "<a id=\"pmt-epub-chapter-2\"></a>\n\nText <a id=\"pmt-epub-chapter-2-anchor-3\"></a>tail\n"
        let preview = RenderedMarkdownPreview.render(source, assets: nil)
        XCTAssertFalse(preview.hasLiteralHTML)
        XCTAssertTrue(preview.html.contains("<span id=\"pmt-epub-chapter-2\"></span>"), preview.html)
        XCTAssertTrue(preview.html.contains("<span id=\"pmt-epub-chapter-2-anchor-3\"></span>"), preview.html)
        XCTAssertNotNil(preview.anchor(for: .init(file: "text.md", utf8Offset: 0, utf8Length: source.utf8.count)))
        for raw in ["<a id=\"pmt-epub-chapter-2\" onclick=\"bad()\"></a>", "<a id=\"other\"></a>", "<a id=\"pmt-epub-chapter-2\">text</a>", "<a id=\"pmt-epub-chapter-0\"></a>"] {
            let result = RenderedMarkdownPreview.render(raw, assets: nil)
            XCTAssertTrue(result.hasLiteralHTML, raw)
            XCTAssertFalse(result.html.contains("<a "), raw)
        }
        for raw in ["`<a id=\"pmt-epub-chapter-2\"></a>`", "```html\n<a id=\"pmt-epub-chapter-2\"></a>\n```"] {
            let result = RenderedMarkdownPreview.render(raw, assets: nil)
            XCTAssertTrue(result.html.contains("&lt;a id="))
            XCTAssertFalse(result.html.contains("<span id=\"pmt-epub-chapter-2\""))
        }
    }

    func testOnlyExactEmptyPresentationAnchorsAreRendered() throws {
        let source = "<a id=\"pmt-slide-2\"></a>\n\n[Jump](#pmt-slide-2)\n"
        let preview = RenderedMarkdownPreview.render(source, assets: nil)
        XCTAssertTrue(preview.html.contains("<span id=\"pmt-slide-2\"></span>"), preview.html)
        for raw in ["<a id=\"pmt-slide-0\"></a>", "<a id=\"pmt-slide-2\" onclick=\"bad()\"></a>", "<a id=\"pmt-slide-2\">bad</a>", "`<a id=\"pmt-slide-2\"></a>`"] {
            let result = RenderedMarkdownPreview.render(raw, assets: nil)
            XCTAssertFalse(result.html.contains("<span id=\"pmt-slide-"), result.html)
        }
    }

    func testOnlyExactEmptyPDFPageAnchorsAreRendered() {
        let source = "<a id=\"pmt-pdf-page-2\"></a>\n\n[Jump](#pmt-pdf-page-2)\n"
        let preview = RenderedMarkdownPreview.render(source,assets: nil)
        XCTAssertFalse(preview.hasLiteralHTML)
        XCTAssertTrue(preview.html.contains("<span id=\"pmt-pdf-page-2\"></span>"))
        for raw in ["<a id=\"pmt-pdf-page-0\"></a>", "<a id=\"pmt-pdf-page-2\" onclick=\"bad()\"></a>", "<a id=\"pmt-pdf-page-2\">bad</a>", "`<a id=\"pmt-pdf-page-2\"></a>`"] {
            XCTAssertFalse(RenderedMarkdownPreview.render(raw,assets: nil).html.contains("<span id=\"pmt-pdf-page-"))
        }
    }

    func testKnownCellAnchorUsesActualUTF8AfterUnicode() throws {
        let source = "# 🙂 title\n\n| Name | Value |\n| --- | --- |\n| Grüße🙂Marker | 42 |\n"
        let prefix = try XCTUnwrap(source.range(of: "Grüße🙂Marker"))
        let offset = source.utf8.distance(from: source.startIndex, to: prefix.lowerBound)
        let preview = RenderedMarkdownPreview.render(source, assets: nil)
        let range = ConversionTextRange(file: "text.md", utf8Offset: offset, utf8Length: "Grüße🙂Marker".utf8.count)
        let anchor = try XCTUnwrap(preview.anchor(for: range))
        XCTAssertTrue(preview.html.contains("id=\"\(anchor.id)\""))
        XCTAssertLessThanOrEqual(anchor.utf8Offset, offset)
        XCTAssertGreaterThanOrEqual(anchor.utf8Offset + anchor.utf8Length, offset + range.utf8Length)
    }

    func testFrontmatterIsMetadataAndKeepsOriginalByteOffsets() throws {
        let source = "---\ntitle: \"Grüße🙂\"\n---\n\n# Actual heading\n\nBodyMarker\n"
        let preview = RenderedMarkdownPreview.render(source, assets: nil)
        XCTAssertTrue(preview.html.contains("<details class=\"metadata\">"))
        XCTAssertTrue(preview.html.contains("Actual heading</h1>"))
        let match = try XCTUnwrap(source.range(of: "BodyMarker"))
        let offset = source.utf8.distance(from: source.startIndex, to: match.lowerBound)
        let anchor = try XCTUnwrap(preview.anchor(for: ConversionTextRange(file: "text.md", utf8Offset: offset, utf8Length: 10)))
        XCTAssertEqual(anchor.utf8Offset, offset)
        let crlf = source.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertTrue(RenderedMarkdownPreview.render(crlf, assets: nil).html.contains("<details class=\"metadata\">"))
    }

    func testOnlyRegisteredLocalAssetsAndOnePercentDecodingAreAccepted() throws {
        let directory = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("Grüße image.png")
        let original = try png
        try original.write(to: file)
        let assets = try PreviewAssets(outputDirectory: root, assets: [file])
        let url = try XCTUnwrap(assets.url(for: "images/Gr%C3%BC%C3%9Fe%20image.png"))
        for target in ["../secret.png", "%2e%2e/secret.png", "/tmp/secret.png", "file:///tmp/secret.png", "https://example.invalid/image.png", "data:image/png;base64,AAAA", "images/missing.png", "images\\Grüße image.png", "images/Grüße image.png?x=1", "images/Grüße image.png#x"] {
            XCTAssertNil(assets.url(for: target), target)
        }
        let thumbnail = try assets.thumbnail(for: url)
        XCTAssertNotNil(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let other = try PreviewAssets(outputDirectory: root, assets: [file])
        XCTAssertThrowsError(try other.thumbnail(for: url))
    }

    func testSymlinkedFilesDirectoriesAndHardlinksCannotEscapeTheResult() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).png")
        let original = try png
        try original.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let directory = root.appendingPathComponent("linked-dir")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside.deletingLastPathComponent())
        let hard = root.appendingPathComponent("hard.png")
        try FileManager.default.linkItem(at: outside, to: hard)
        let nested = directory.appendingPathComponent(outside.lastPathComponent)
        let assets = try PreviewAssets(outputDirectory: root, assets: [link, hard, nested])
        for target in ["linked.png", "hard.png", "linked-dir/\(outside.lastPathComponent)"] {
            let url = try XCTUnwrap(assets.url(for: target))
            XCTAssertThrowsError(try assets.thumbnail(for: url))
        }
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testSVGAndOversizedAssetsAreRejectedBeforeDecoding() throws {
        let svg = root.appendingPathComponent("pretend.png")
        let original = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"https://example.invalid/tracker.png\"/></svg>".utf8)
        try original.write(to: svg)
        let huge = root.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(PreviewAssets.maximumSourceBytes + 1)); try handle.close()
        let assets = try PreviewAssets(outputDirectory: root, assets: [svg, huge])
        for name in ["pretend.png", "huge.png"] { XCTAssertThrowsError(try assets.thumbnail(for: XCTUnwrap(assets.url(for: name)))) }
        XCTAssertEqual(try Data(contentsOf: svg), original)
    }

    func testPreviewVerifiesTheSameReadAndRejectsStaleRangesAndSymlinkedMarkdown() throws {
        let file = root.appendingPathComponent("text.md")
        let original = Data("# Title🙂\n".utf8)
        try original.write(to: file)
        let expected = ConversionOutputFile(path: "text.md", sha256: ConversionFileFingerprint.digest(original), byteCount: original.count)
        XCTAssertEqual(try MarkdownPreview.read(file, expected: expected).matchesExpectedOutput, true)
        try Data((String(repeating: "changed ", count: 100) + "🙂").utf8).write(to: file)
        let stale = try MarkdownPreview.read(file, limit: 200, expected: expected)
        XCTAssertEqual(stale.matchesExpectedOutput, false)
        XCTAssertTrue(stale.truncated)
        XCTAssertGreaterThan(stale.text.utf8.count, original.count)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try MarkdownPreview.read(link))
    }

    func testLargeAndDeepPreviewsAreLimitedWithoutInvalidAnchors() {
        let large = RenderedMarkdownPreview.render(String(repeating: "<script>Literal</script>\n", count: 20_000), assets: nil)
        XCTAssertTrue(large.limited)
        XCTAssertLessThan(large.html.utf8.count, 1_100_000)
        XCTAssertFalse(large.html.contains("<script>"))
        let expression = try! NSRegularExpression(pattern: #"id="(pmt-\d+)""#)
        let ids = Set(expression.matches(in: large.html, range: NSRange(large.html.startIndex..., in: large.html)).compactMap {
            Range($0.range(at: 1), in: large.html).map { String(large.html[$0]) }
        })
        XCTAssertTrue(large.anchors.allSatisfy { ids.contains($0.id) })
        let deep = RenderedMarkdownPreview.render(String(repeating: "> ", count: 100) + "Deep marker", assets: nil)
        XCTAssertTrue(deep.limited)
        XCTAssertTrue(deep.anchors.isEmpty)
    }
}
