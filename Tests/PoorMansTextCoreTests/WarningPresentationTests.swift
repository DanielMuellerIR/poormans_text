import Foundation
import XCTest
@testable import PoorMansTextAppSupport

final class WarningPresentationTests: XCTestCase {
    func testKeepsEveryWarningForScrollablePresentation() {
        let warnings = ["First attachment is missing.", "Second attachment is missing."]

        let presentation = WarningPresentation(warnings: warnings)

        XCTAssertEqual(presentation.messages, warnings)
        XCTAssertEqual(presentation.messages.count, 2)
    }
}
