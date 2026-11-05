#if os(Linux)
import XCTest
import Foundation
@testable import PoorMansTextCore

final class LinuxPDFTests: XCTestCase {
    func testInvalidPDFSignatureIsRejectedBeforeBackend() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Invalid-\(UUID().uuidString).pdf")
        try Data("not a PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try LinuxPDFAdapter().inspectInput(at: url)
        guard case let .invalid(format, _, reason) = result else { return XCTFail("Invalid PDF accepted") }
        XCTAssertEqual(format, .pdf)
        XCTAssertTrue(reason.contains("signature"))
    }
    func testPortableMarginsDoNotRemoveSameTextInBody() {
        let header = PDFTextLine(text: "Repeated", bounds: CGRect(x: 20, y: 760, width: 100, height: 20))
        let body = PDFTextLine(text: "Repeated", bounds: CGRect(x: 20, y: 380, width: 100, height: 20))
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let filtered = PDFTextLayout.removingRepeatedMargins([[header, body], [header]], bounds: [bounds, bounds])
        XCTAssertEqual(filtered[0].map(\.text), ["Repeated"])
        XCTAssertEqual(filtered[0][0].bounds, body.bounds)
        XCTAssertTrue(filtered[1].isEmpty)
    }
    func testPortableLineOrderPreservesWordInventoryAndHyphenationIsConservative() {
        let source = [PDFTextLine(text: "GAMMA", bounds: CGRect(x: 20, y: 500, width: 100, height: 20)),
                      PDFTextLine(text: "BETA", bounds: CGRect(x: 300, y: 700, width: 100, height: 20)),
                      PDFTextLine(text: "ALPHA", bounds: CGRect(x: 20, y: 700, width: 100, height: 20))]
        let ordered = PDFTextLayout.ordered(source, pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800))
        XCTAssertEqual(ordered.map(\.text), ["ALPHA", "BETA", "GAMMA"])
        XCTAssertEqual(ordered.map(\.text).sorted(), source.map(\.text).sorted())
        XCTAssertEqual(PDFTextLayout.cleanedHyphenation("fortsetzungs-\nbeispiel\nA-\nB\n123-\n456", hardHyphens: true), "fortsetzungsbeispiel\nA-\nB\n123-\n456")
    }
    func testPhysicalWordGapsDoNotGlueTableCellText() throws {
        let text = "Butterfly SplitfinAmeca splendens\nGolden SkiffiaSkiffia francesae"
        var boxes = [[Double]](), x = 0.0, y = 40.0
        var index = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" { boxes.append([x, y, 0, 0]); x = 0; y -= 20 }
            else {
                // Gemessene Zellgrenzen der natürlichen DP-Bench-Seite 132.
                if index == "Butterfly Splitfin".unicodeScalars.count { x += 8.7561 }
                if index == "Butterfly SplitfinAmeca splendens\nGolden Skiffia".unicodeScalars.count { x += 18.7839 }
                boxes.append([x, y, 5, 10.5867]); x += 5
            }
            index += 1
        }
        let lines = try XCTUnwrap(LinuxPDFTextGeometry.lines(text: text, rectangles: boxes))
        XCTAssertEqual(lines, ["Butterfly Splitfin Ameca splendens", "Golden Skiffia Skiffia francesae"])
        XCTAssertEqual(lines.joined().filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
        XCTAssertEqual(LinuxPDFTextGeometry.lines(text: "CamelCase", rectangles: (0..<9).map { [Double($0) * 5, 0, 5, 10] }), ["CamelCase"])
        XCTAssertNil(LinuxPDFTextGeometry.lines(text: "אב", rectangles: [[0, 0, 5, 10], [15, 0, 5, 10]]))
    }
    func testActualNaturalPDFKeepsSeparatedCellWords() throws {
        guard ExternalToolResolver().isAvailable(.pythonPoppler) else { throw XCTSkip("Local Poppler backend not installed") }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PoorMansTextCoreTests/Fixtures/LinuxPDF/word-gaps.pdf")
        let original = try Data(contentsOf: source)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFWordGaps-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent("out")), options: .init(pdfTextRecognition: .disabled)))
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        let text = markdown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(text.contains("Butterfly Splitfin Ameca splendens"), text)
        XCTAssertTrue(text.contains("Golden Skiffia Skiffia francesae"), text)
        XCTAssertFalse(text.contains("SplitfinAmeca"))
        XCTAssertFalse(text.contains("SkiffiaSkiffia"))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testActualHostPDFOverview() throws {
        guard let fixture = ProcessInfo.processInfo.environment["PMT_PDF_FIXTURE"] else { throw XCTSkip("Host PDF fixture not selected") }
        let url = URL(fileURLWithPath: fixture)
        let source = try Data(contentsOf: url)
        let result = try LinuxPDFAdapter().inspectContents(at: url, maximumPages: 1)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(result.pages[0].width, 600)
        XCTAssertEqual(result.pages[0].height, 800)
        XCTAssertTrue(result.pagesTruncated)
        XCTAssertEqual(result.sourceIdentity.byteCount, source.count)
        XCTAssertEqual(try Data(contentsOf: url), source)
    }
}
#endif
