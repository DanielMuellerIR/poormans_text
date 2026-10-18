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
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "87")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["NSHumanReadableCopyright"] as? String, "© 2026 Daniel Müller")
        let documentTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let extensions = documentTypes.flatMap {
            $0["CFBundleTypeExtensions"] as? [String] ?? []
        }
        // Die App muss genau die Endungen anmelden, die der Kern liest — sonst
        // öffnet der Finder ein Format nicht, das die CLI längst kann.
        XCTAssertEqual(
            Set(extensions),
            Set(DocumentConverter().supportedFormatDescriptors.flatMap(\.fileExtensions))
        )
    }

    func testENEXRegistrationAcceptsNativeEvernoteAndFallbackTypes() throws {
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: projectRoot.appendingPathComponent("App/Info.plist")), format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let enex = try XCTUnwrap(types.first { ($0["CFBundleTypeExtensions"] as? [String])?.contains("enex") == true })
        let aliases = Set(["com.evernote.enex", "org.poormanstext.enex"])
        XCTAssertTrue(aliases.isSubset(of: Set(try XCTUnwrap(enex["LSItemContentTypes"] as? [String]))))
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let files = try XCTUnwrap(services.first { $0["NSMessage"] as? String == "convertFilesToMarkdown" })
        XCTAssertTrue(aliases.isSubset(of: Set(try XCTUnwrap(files["NSSendFileTypes"] as? [String]))))
    }

    func testPublicDocumentationNamesCurrentVersion() throws {
        for filename in ["README.md", "README.de.md"] {
            let contents = try String(
                contentsOf: projectRoot.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertTrue(contents.contains(ProductInfo.version), "\(filename) has no current version")
        }

        let changelog = try String(
            contentsOf: projectRoot.appendingPathComponent("CHANGELOG.md"),
            encoding: .utf8
        )
        XCTAssertTrue(changelog.contains("## 0.14.0 — 2026-09-30"))
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
