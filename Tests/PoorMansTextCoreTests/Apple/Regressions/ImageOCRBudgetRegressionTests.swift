import Foundation
import XCTest
@testable import PoorMansTextCore

final class ImageOCRBudgetRegressionTests: XCTestCase {
    func testNarrowImageBudgetAccountsForTheOnePixelMinimumEdge() {
        XCTAssertEqual(
            ImageOCRBudget.maximumEdge(width: 100_000, height: 1, budget: 64_000),
            64_000
        )
        XCTAssertNil(ImageOCRBudget.maximumEdge(width: 200, height: 100, budget: 20_000))
    }
}
