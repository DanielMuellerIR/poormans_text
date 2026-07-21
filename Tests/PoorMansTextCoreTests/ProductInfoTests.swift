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
        let plistURL = projectRoot.appendingPathComponent("App/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, ProductInfo.version)
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "4")
    }

    func testPublicDocumentationNamesCurrentVersion() throws {
        for filename in ["README.md", "README.de.md"] {
            let contents = try String(
                contentsOf: projectRoot.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertTrue(contents.contains("0.4.0"), "\(filename) has no current version")
        }

        let changelog = try String(
            contentsOf: projectRoot.appendingPathComponent("CHANGELOG.md"),
            encoding: .utf8
        )
        XCTAssertTrue(changelog.contains("## 0.4.0 - 2026-07-21"))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
