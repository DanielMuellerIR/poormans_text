import Foundation
import XCTest
@testable import PoorMansTextCore

final class RTFHighlightTests: XCTestCase {
    private let colors = #"{\colortbl;\red255\green255\blue0;}"#

    private func convert(_ body: String, check: (String, ConversionResult) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pmt-rtf-highlight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("marked.rtf")
        let bytes = Data((#"{\rtf1\ansi\uc1"# + colors + " " + body + "}").utf8)
        try bytes.write(to: source)
        let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(conversionReport: true)))
        try check(String(contentsOf: result.markdownFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), result)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let report = try XCTUnwrap(result.reportFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
    }

    func testHighlightBoldAndUnicodeReachFinalMarkdown() throws {
        try convert(#"Plain {\b Bold} \highlight1 Marked\highlight0  \u196?"#) { markdown, result in
            XCTAssertEqual(markdown, "Plain **Bold** ==Marked== Ä")
            XCTAssertTrue(result.diagnostics.contains { $0.code == "richText.highlightColorApproximation" })
        }
    }

    func testGroupsAndPlainRestoreBackgroundState() throws {
        try convert(#"Before {\highlight1 Alpha {\highlight0 middle} Omega} After \highlight1 Last\plain  End"#) { markdown, _ in
            XCTAssertEqual(markdown, "Before ==Alpha== middle ==Omega== After ==Last== End")
        }
    }

    func testParagraphsAndLineBreaksHaveIndependentMarkers() throws {
        try convert(#"\highlight1 First\par Second\line Third\highlight0"#) { markdown, _ in
            for token in ["==First==", "==Second==", "==Third=="] { XCTAssertTrue(markdown.contains(token), markdown) }
            XCTAssertEqual(markdown.components(separatedBy: "==").count - 1, 6)
        }
    }

    func testBothCharacterBackgroundControlsArePreserved() throws {
        for control in ["chcbpat", "cb"] {
            try convert("\\" + control + "1 Marked\\" + control + "0  Plain") { markdown, _ in
                XCTAssertEqual(markdown, "==Marked== Plain")
            }
        }
    }

    func testWhitespaceAndLiteralDelimiterRemainContent() throws {
        try convert(#"\highlight1   spaced  \highlight0 End"#) { markdown, _ in
            XCTAssertTrue(markdown.contains("==spaced=="), markdown)
            XCTAssertFalse(markdown.contains("== spaced"), markdown)
        }
        try convert(#"\highlight1 a==b\highlight0"#) { markdown, _ in
            XCTAssertEqual(markdown, "<mark>a==b</mark>")
        }
    }

    func testIgnoredAndEscapedControlsCannotInventHighlights() throws {
        let source = Data(#"{\rtf1{\*\ignored \highlight1 hidden} Literal \\highlight1}"#.utf8)
        let protected = try RTFUnicodeProtector.protect(source)
        XCTAssertEqual(protected.highlightedRunCount, 0)
        XCTAssertEqual(protected.data, source)
    }

    func testUnicodePairsInsideHighlightKeepExactScalar() throws {
        try convert(#"\highlight1 A\u-10179?\u-8704?B\highlight0"#) { markdown, _ in
            XCTAssertEqual(markdown, "==A😀B==")
        }
    }
}
