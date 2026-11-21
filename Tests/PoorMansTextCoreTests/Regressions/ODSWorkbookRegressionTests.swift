import Foundation
import XCTest
@testable import PoorMansTextCore

final class ODSWorkbookRegressionTests: XCTestCase {
    func testODSAnnotationPreservesSurroundingCellTextAndNamespaceAttributes() throws {
        let xml = """
        <o:document-content xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
         xmlns:t="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
         xmlns:x="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:other="urn:extension">
        <o:body><o:spreadsheet><t:table other:name="Wrong" t:name="Correct"><t:table-row other:number-rows-repeated="8" t:number-rows-repeated="1">
        <t:table-cell other:value-type="boolean" o:value-type="string" other:number-columns-repeated="5" t:number-columns-repeated="1">
        <x:p>before<o:annotation><x:p>NOTE</x:p></o:annotation>after<x:s other:c="1" x:c="20"/>end</x:p><x:p>next</x:p>
        </t:table-cell><t:table-cell o:value-type="float" other:value="999" o:value="42" t:formula="of:=6*7" other:formula="wrong"/>
        </t:table-row></t:table></o:spreadsheet></o:body></o:document-content>
        """
        let workbook = try ODSWorkbookParser.parse(Data(xml.utf8))
        XCTAssertEqual(workbook.sheets.map(\.name), ["Correct"])
        XCTAssertEqual(workbook.sheets[0].rows.count, 1)
        XCTAssertEqual(workbook.sheets[0].rows[0].count, 2)
        XCTAssertEqual(workbook.sheets[0].rows[0][0].displayText, "beforeafter" + String(repeating: " ", count: 20) + "end\nnext")
        XCTAssertEqual(workbook.sheets[0].rows[0][1].displayText, "42")
        XCTAssertEqual(workbook.sheets[0].rows[0][1].formula, "of:=6*7")
        XCTAssertTrue(workbook.hasUnsupportedObjects)
    }

    func testODSIntermediateEmptyRowsShareTheWorkbookBudget() throws {
        let root = try makeRegressionDirectory()
        let sheet = "<table:table table:name=\"S\"><table:table-row table:number-rows-repeated=\"900000\"><table:table-cell/></table:table-row><table:table-row><table:table-cell office:value-type=\"string\"><text:p>VALUE</text:p></table:table-cell></table:table-row></table:table>"
        let xml = "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:spreadsheet>\(String(repeating: sheet, count: 12))</office:spreadsheet></office:body></office:document-content>"
        let source = root.appendingPathComponent("budget.ods")
        let bytes = try ZIPFixtureBuilder.odsPackage(contentXML: xml)
        try bytes.write(to: source)
        XCTAssertThrowsError(try DocumentConverter().inspect(source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cell budget"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let small = xml.replacingOccurrences(of: "900000", with: "2")
        let workbook = try ODSWorkbookParser.parse(Data(small.utf8))
        XCTAssertEqual(workbook.sheets.count, 12)
        for sheet in workbook.sheets {
            XCTAssertEqual(sheet.rows.count, 3)
            XCTAssertTrue(sheet.rows[0].isEmpty && sheet.rows[1].isEmpty)
            XCTAssertEqual(sheet.rows[2].map(\.displayText), ["VALUE"])
        }
    }
}
