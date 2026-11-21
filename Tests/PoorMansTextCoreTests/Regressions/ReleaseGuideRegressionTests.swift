import Foundation
import XCTest
@testable import PoorMansTextCore

final class ReleaseGuideRegressionTests: XCTestCase {
    func testReleaseGuideDerivesTheVersionInsteadOfNamingIt() throws {
        let guideURL = RegressionFixtures.projectRoot.appendingPathComponent("docs/GITHUB-RELEASE.md")
        let guide = try String(contentsOf: guideURL, encoding: .utf8)

        XCTAssertTrue(guide.contains("Sources/PoorMansTextCore/ProductInfo.swift"))
        XCTAssertTrue(guide.contains("$VERSION"))
        let literalVersions = guide.matches(of: /[0-9]+\.[0-9]+\.[0-9]+/).map { String($0.output) }
        XCTAssertEqual(literalVersions, [], "Die Anleitung nennt noch feste Versionen")
    }
}
