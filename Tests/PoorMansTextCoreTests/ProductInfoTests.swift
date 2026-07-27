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
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "7")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["NSHumanReadableCopyright"] as? String, "© 2026 Daniel Müller")
        let documentTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let extensions = documentTypes.flatMap {
            $0["CFBundleTypeExtensions"] as? [String] ?? []
        }
        XCTAssertEqual(Set(extensions), ["rtf", "rtfd", "docx", "odt", "doc"])
    }

    func testPublicDocumentationNamesCurrentVersion() throws {
        for filename in ["README.md", "README.de.md"] {
            let contents = try String(
                contentsOf: projectRoot.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertTrue(contents.contains("0.6.0"), "\(filename) has no current version")
        }

        let changelog = try String(
            contentsOf: projectRoot.appendingPathComponent("CHANGELOG.md"),
            encoding: .utf8
        )
        XCTAssertTrue(changelog.contains("## 0.6.0 - 2026-07-27"))
    }

    func testPublicLicenseMetadataUsesWTFPLVersion2() throws {
        let license = try String(
            contentsOf: projectRoot.appendingPathComponent("LICENSE"),
            encoding: .utf8
        )
        XCTAssertTrue(license.contains("DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE"))
        XCTAssertTrue(license.contains("Version 2, December 2004"))
        XCTAssertTrue(license.contains("not part of the license text"))

        for filename in ["README.md", "README.de.md"] {
            let contents = try String(
                contentsOf: projectRoot.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertTrue(contents.contains("**WTFPL**, Version 2"))
            XCTAssertTrue(contents.contains("[LICENSE](LICENSE)"))
        }
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
