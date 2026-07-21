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

    func testAppBundleVersionMatchesSharedProductVersion() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("App/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, ProductInfo.version)
    }
}
