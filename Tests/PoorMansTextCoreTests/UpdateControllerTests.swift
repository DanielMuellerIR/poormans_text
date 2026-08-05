import Foundation
import XCTest
@testable import PoorMansTextAppSupport

final class UpdateControllerTests: XCTestCase {
    /// Ohne gestarteten Updater darf der Menüpunkt nicht anbieten, was er nicht
    /// kann — und ein trotzdem ausgelöster Aufruf darf keinen Suchlauf starten.
    @MainActor
    func testControllerWithoutStartedUpdaterOffersNoCheck() {
        let controller = UpdateController(startsUpdater: false)

        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertFalse(controller.canCheckForUpdates)
    }

    /// Der Updater tauscht die installierte App aus. Ein unsignierter Feed oder
    /// ein Feed ohne Transportverschlüsselung würde genau das angreifbar machen.
    func testUpdateSettingsRequireSignedFeedOverHTTPS() throws {
        let plist = try appInfoPlist()

        let feedURL = try XCTUnwrap(
            URL(string: try XCTUnwrap(plist["SUFeedURL"] as? String))
        )
        XCTAssertEqual(feedURL.scheme, "https")
        XCTAssertEqual(feedURL.lastPathComponent, "appcast.xml")

        // Sparkle erwartet den öffentlichen Ed25519-Schlüssel als Base64. Ein
        // Ed25519-Schlüssel ist genau 32 Byte lang.
        let publicKey = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)

        XCTAssertEqual(plist["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
    }

    /// Gesucht wird selbsttätig, installiert nur nach Zustimmung — und die App
    /// überträgt dabei kein Systemprofil.
    func testUpdateSettingsKeepInstallationAndProfilingOptional() throws {
        let plist = try appInfoPlist()

        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(plist["SUEnableSystemProfiling"] as? Bool, false)
    }

    private func appInfoPlist() throws -> [String: Any] {
        let plistURL = projectRoot.appendingPathComponent("App/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any]
        )
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
