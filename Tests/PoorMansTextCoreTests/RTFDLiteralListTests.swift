import AppKit
import XCTest
@testable import PoorMansTextCore

final class RTFDLiteralListTests: XCTestCase {
    func testImportsLiteralBulletsAsTightListsWithoutLosingParagraphsOrFormatting() throws {
        _ = try PandocTool.resolve(nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RTFDLiteralLists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "Suchfeld\n• Alle = OK\n__________________\n• Suchfeld = OK\n• Art = OK\n\n• Firma = OK\n• Vorname = OK\nSchluss eins\nSchluss zwei\n"
        let document = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.systemTeal,
        ])
        document.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14),
                              range: (text as NSString).range(of: "Suchfeld = OK"))
        document.addAttribute(.link, value: URL(string: "https://example.com/art")!,
                              range: (text as NSString).range(of: "Art = OK"))
        let input = root.appendingPathComponent("Aufzählung.rtfd")
        try document.fileWrapper(from: NSRange(location: 0, length: document.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            .write(to: input, options: .atomic, originalContentsURL: nil)
        let source = try Data(contentsOf: input.appendingPathComponent("TXT.rtf"))
        let result = try RichTextConverter().convert(inputURL: input)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        let lines = markdown.components(separatedBy: "\n")
        let itemLines = lines.enumerated().filter { $0.element.hasPrefix("- ") }
        XCTAssertEqual(itemLines.count, 5, markdown)
        XCTAssertFalse(markdown.contains("•"), markdown)
        let field = try XCTUnwrap(lines.firstIndex { $0.contains("**Suchfeld = OK**") })
        let kind = try XCTUnwrap(lines.firstIndex { $0.contains("[Art = OK](https://example.com/art)") })
        XCTAssertEqual(kind, field + 1, markdown)
        XCTAssertTrue(lines[field].contains("=="), markdown)
        XCTAssertTrue(lines[kind].contains("=="), markdown)
        XCTAssertTrue(markdown.contains("Schluss eins==\n\n==Schluss zwei"), markdown)
        // Ein echter leerer Quellabsatz zwischen zwei Listen bleibt sichtbar.
        XCTAssertTrue(markdown.contains("  \n"), markdown)
        XCTAssertEqual(try Data(contentsOf: input.appendingPathComponent("TXT.rtf")), source)
        for content in ["Alle", "Suchfeld = OK", "Art = OK", "Firma = OK", "Vorname = OK", "Schluss eins", "Schluss zwei"] {
            XCTAssertEqual(markdown.components(separatedBy: content).count - 1, 1, markdown)
        }
    }

    func testImportsUncoloredBulletsAndKeepsManualLineBreaks() throws {
        _ = try PandocTool.resolve(nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RTFDUncoloredLists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = NSAttributedString(string: "• Eins\u{2028}Fortsetzung\n• Zwei\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let input = root.appendingPathComponent("Liste.rtfd")
        try document.fileWrapper(from: NSRange(location: 0, length: document.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            .write(to: input, options: .atomic, originalContentsURL: nil)
        let result = try RichTextConverter().convert(inputURL: input)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown, "- Eins  \n  Fortsetzung\n- Zwei\n")
    }

    func testOnlyConvertsParagraphInitialBulletWithFollowingWhitespace() {
        let text = "Im Text • bleibt\n•ohne Abstand\n• \n• Eins\n\t•\tZwei\nNormal\n• Drei\n"
        let document = NSMutableAttributedString(string: text)
        XCTAssertEqual(RTFDLiteralListNormalizer.normalize(document), 3)
        XCTAssertEqual(document.string, "Im Text • bleibt\n•ohne Abstand\n• \nEins\nZwei\nNormal\nDrei\n")
        let content = document.string as NSString
        let first = document.attribute(.paragraphStyle, at: content.range(of: "Eins").location,
                                       effectiveRange: nil) as? NSParagraphStyle
        let second = document.attribute(.paragraphStyle, at: content.range(of: "Zwei").location,
                                        effectiveRange: nil) as? NSParagraphStyle
        let third = document.attribute(.paragraphStyle, at: content.range(of: "Drei").location,
                                       effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(first?.textLists.first === second?.textLists.first)
        XCTAssertFalse(first?.textLists.first === third?.textLists.first)
        XCTAssertEqual(RTFDLiteralListNormalizer.normalize(document), 0)
    }

    func testLeavesExistingListsAndTheirLiteralContentUntouched() {
        let document = NSMutableAttributedString(string: "• Original\nSecond\n")
        let style = NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
        document.addAttribute(.paragraphStyle, value: style,
                              range: NSRange(location: 0, length: document.length))
        let before = NSAttributedString(attributedString: document)
        XCTAssertEqual(RTFDLiteralListNormalizer.normalize(document), 0)
        XCTAssertEqual(document, before)
    }
}
