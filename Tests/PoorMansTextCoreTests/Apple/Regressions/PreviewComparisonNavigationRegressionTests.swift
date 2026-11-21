import Foundation
import XCTest
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class PreviewComparisonNavigationRegressionTests: XCTestCase {
    func testSameNamedSheetsKeepExactAndCoarseCellsInTheChosenSheet() throws {
        let mappings = [
            ConversionSourceMapping(source: .init(sheet: "Same", cell: "A1", sheetIndex: 1), output: .init(file: "text.md", utf8Offset: 10, utf8Length: 5)),
            ConversionSourceMapping(source: .init(sheet: "Same", cell: "B2", sheetIndex: 2), output: .init(file: "text.md", utf8Offset: 20, utf8Length: 5)),
            ConversionSourceMapping(source: .init(sheet: "Same", cell: "C3", sheetIndex: 1), output: .init(file: "text.md", utf8Offset: 30, utf8Length: 5)),
            ConversionSourceMapping(source: .init(sheet: "Same", cell: "C3", sheetIndex: 2), output: .init(file: "text.md", utf8Offset: 40, utf8Length: 5))
        ]
        let coarse = try XCTUnwrap(ComparisonNavigation.target(for: .init(sheet: "Same", cell: "B2", sheetIndex: 1), mappings: mappings))
        XCTAssertFalse(coarse.exact); XCTAssertEqual(coarse.range.utf8Offset, 10)
        for index in 1...2 {
            let exact = try XCTUnwrap(ComparisonNavigation.target(for: .init(sheet: "Same", cell: "C3", sheetIndex: index), mappings: mappings))
            XCTAssertTrue(exact.exact); XCTAssertEqual(exact.range.utf8Offset, index == 1 ? 30 : 40)
        }
    }
}
