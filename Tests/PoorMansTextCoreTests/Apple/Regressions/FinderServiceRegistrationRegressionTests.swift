import Foundation
import XCTest
@testable import PoorMansTextCore

final class FinderServiceRegistrationRegressionTests: XCTestCase {
    func testTheFinderServiceAcceptsEveryRegisteredDocumentContentType() throws {
        let plistURL = RegressionFixtures.projectRoot.appendingPathComponent("App/Info.plist")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        )
        let documentTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let contentTypes = Set(documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let fileService = try XCTUnwrap(services.first { $0["NSSendFileTypes"] != nil })
        let sendFileTypes = Set(try XCTUnwrap(fileService["NSSendFileTypes"] as? [String]))

        // Ohne Kontext registriert macOS Dienste, bietet sie jedoch nicht
        // automatisch im Menü an. Der Port gehört zum App-Dienstanbieter.
        for service in services {
            XCTAssertNotNil(service["NSRequiredContext"] as? [String: Any])
            XCTAssertEqual(service["NSPortName"] as? String, plist["CFBundleName"] as? String)
        }

        // Jeder Dokumenttyp, den die App öffnet, muss auch im Finder-Dienst
        // stehen; nur `public.folder` gehört allein dem Dienst.
        XCTAssertEqual(contentTypes.subtracting(sendFileTypes), [])
        XCTAssertEqual(sendFileTypes.subtracting(contentTypes), ["public.folder"])
    }
}
