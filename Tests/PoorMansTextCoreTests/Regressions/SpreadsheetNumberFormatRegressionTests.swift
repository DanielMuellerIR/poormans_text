import Foundation
import XCTest
@testable import PoorMansTextCore

final class SpreadsheetNumberFormatRegressionTests: XCTestCase {
    func testPreciseDayFractionsKeepTheirDateTimeAndDurationBeforeMidnight() {
        let cases = [("46311.999999999999999999", "yyyy-mm-dd hh:mm", "2026-10-16 23:59"),
                     ("0.999999999999999999", "hh:mm", "23:59"),
                     ("0.99999999999999999999999999999999999999", "hh:mm", "23:59"),
                     ("1.999999999999999999", "[h]:mm", "47:59")]
        for (value, format, expected) in cases {
            let result = SpreadsheetNumberFormat(code: format).format(value)
            XCTAssertEqual(result.text, expected, "\(value) / \(format)")
            XCTAssertNil(result.issue)
        }
    }
}
