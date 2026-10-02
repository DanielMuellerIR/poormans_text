import Foundation
import XCTest
@testable import PoorMansTextCore

final class XMLTextContentTests: XCTestCase {
    func testCDATAReachesODSAndODMConversionWithoutLosingText() throws {
        let paragraph = "<text:p>before<![CDATA[IMPORTANT]]>after</text:p>"
        let ods = odsXML(paragraph)
        let odm = """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text>\(paragraph)<text:p><![CDATA[SECOND]]></text:p></office:text></office:body></office:document-content>
        """
        try withRoot { root in
            for (ext, bytes) in [("ods", try ZIPFixtureBuilder.odsPackage(contentXML: ods)),
                                 ("odm", try ZIPFixtureBuilder.odmPackage(contentXML: odm))] {
                let source = root.appendingPathComponent("text.\(ext)")
                try bytes.write(to: source)
                let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
                    destination: .directory(root.appendingPathComponent("result-\(ext)"))))
                let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
                XCTAssertEqual(markdown.components(separatedBy: "beforeIMPORTANTafter").count - 1, 1, markdown)
                if ext == "odm" { XCTAssertEqual(markdown.components(separatedBy: "SECOND").count - 1, 1) }
                XCTAssertEqual(try Data(contentsOf: source), bytes)
            }
        }
    }

    func testCDATAReachesXLSXSharedStringsInlineTextAndValues() throws {
        let sheet = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t><![CDATA[INLINE]]></t></is></c><c r="C1" t="b"><v><![CDATA[1]]></v></c><c r="D1"><v><![CDATA[42]]></v></c></row></sheetData></worksheet>
        """
        let shared = """
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>before<![CDATA[SHARED]]>after</t></si></sst>
        """
        try withRoot { root in
            let source = root.appendingPathComponent("text.xlsx")
            let bytes = try ZIPFixtureBuilder.xlsxPackage(firstSheetXML: sheet,
                secondSheetXML: sheet, sharedStringsOverride: shared)
            try bytes.write(to: source)
            let workbook = try XLSXWorkbookParser.parse(packageAt: source)
            XCTAssertEqual(workbook.sheets[0].rows[0].map(\.displayText), ["beforeSHAREDafter", "INLINE", "TRUE", "42"])
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertEqual(markdown.components(separatedBy: "beforeSHAREDafter").count - 1, 2, markdown)
            XCTAssertEqual(markdown.components(separatedBy: "INLINE").count - 1, 2, markdown)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testODSExplicitSpacesArePreservedAndBoundedBeforeExpansion() throws {
        let xml = odsXML("<text:p>A<text:s text:c=\"20000\"/>B</text:p>")
        let workbook = try ODSWorkbookParser.parse(Data(xml.utf8))
        XCTAssertEqual(workbook.sheets[0].rows[0][0].displayText, "A" + String(repeating: " ", count: 20000) + "B")
        let tooLarge = odsXML("<text:p><text:s text:c=\"\(SpreadsheetLimits.maximumOutputBytes + 1)\"/></text:p>")
        XCTAssertThrowsError(try ODSWorkbookParser.parse(Data(tooLarge.utf8)))
        let exact = odsXML("<text:p>A<text:s text:c=\"6\"/>B</text:p>")
        XCTAssertNoThrow(try ODSWorkbookParser.parse(Data(exact.utf8), maximumTextBytes: 8))
        for content in ["<text:s text:c=\"5\"/><text:s text:c=\"4\"/>", "123456789", "<![CDATA[123456789]]>"] {
            XCTAssertThrowsError(try ODSWorkbookParser.parse(Data(odsXML("<text:p>\(content)</text:p>").utf8), maximumTextBytes: 8))
        }
    }

    private func odsXML(_ content: String) -> String {
        """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"><office:body><office:spreadsheet><table:table table:name="Text"><table:table-row><table:table-cell office:value-type="string">\(content)</table:table-cell></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>
        """
    }

    func testODMExplicitSpacesArePreserved() throws {
        let xml = """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>A<text:s text:c="2000"/>B</text:p></office:text></office:body></office:document-content>
        """
        let items = try ODMContentParser.parse(Data(xml.utf8))
        guard case .markdown(let text) = items.first else { return XCTFail("Expected paragraph") }
        XCTAssertEqual(text.count, 2002)
        XCTAssertEqual(text.filter { $0 == " " }.count, 2000)
        XCTAssertThrowsError(try ODMContentParser.parse(Data(xml.utf8), maximumTextBytes: 100))
        let huge = xml.replacingOccurrences(of: "text:c=\"2000\"", with: "text:c=\"999999999999\"")
        XCTAssertThrowsError(try ODMContentParser.parse(Data(huge.utf8)))
    }

    private func withRoot(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }
}
