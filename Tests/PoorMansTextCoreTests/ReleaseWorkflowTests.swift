import Foundation
import XCTest

final class ReleaseWorkflowTests: XCTestCase {
    func testAppcastUsesTheRequestedTagAndResolvesPackagesBeforeSecretInjection() throws {
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)
        let checkout = try XCTUnwrap(workflow.range(of: "- name: Check out source"))
        let resolve = try XCTUnwrap(workflow.range(of: "- name: Resolve pinned Sparkle package"))
        let signing = try XCTUnwrap(workflow.range(of: "- name: Generate signed appcast"))
        let upload = try XCTUnwrap(workflow.range(of: "- name: Upload Pages artifact"))
        let checkoutBlock = workflow[checkout.lowerBound..<resolve.lowerBound]
        let signingBlock = workflow[signing.lowerBound..<upload.lowerBound]

        XCTAssertTrue(checkoutBlock.contains("ref: ${{ env.RELEASE_TAG }}"))
        XCTAssertTrue(checkoutBlock.contains(#"git rev-parse "$RELEASE_TAG^{commit}""#))
        XCTAssertLessThan(resolve.lowerBound, signing.lowerBound)
        XCTAssertTrue(workflow[resolve.lowerBound..<signing.lowerBound].contains("swift package resolve"))
        XCTAssertFalse(signingBlock.contains("swift package resolve"))
        XCTAssertTrue(signingBlock.contains("sparkle_private_key=\"$SPARKLE_PRIVATE_KEY\""))
        XCTAssertTrue(signingBlock.contains("unset SPARKLE_PRIVATE_KEY"))
        XCTAssertTrue(signingBlock.contains(#"printf '%s' "$sparkle_private_key" | "$tool""#))
        XCTAssertFalse(signingBlock.contains(#"printf '%s' "$SPARKLE_PRIVATE_KEY""#))
    }

    private var workflowURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/publish-appcast.yml")
    }
}
