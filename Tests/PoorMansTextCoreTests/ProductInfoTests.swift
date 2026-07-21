import XCTest
@testable import PoorMansTextCore

final class ProductInfoTests: XCTestCase {
    func testVersionUsesSemanticVersioning() {
        XCTAssertNotNil(
            ProductInfo.version.wholeMatch(
                of: /[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?/
            )
        )
    }
}

