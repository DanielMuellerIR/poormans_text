import Foundation
import XCTest

final class ReleaseWorkflowTests: XCTestCase {
    func testUniversalCodeDirectoryComparisonChecksBothArchitectures() throws {
        let helper = workflowURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/code_directory_hash.sh")
        let script = #"""
        set -euo pipefail
        source "$1"
        codesign() {
            case "$3:$5" in
                x86_64:different) echo 'CDHash=different' >&2 ;;
                x86_64:missing) echo 'no hash' >&2 ;;
                x86_64:failure) return 42 ;;
                *) echo 'CDHash=same' >&2 ;;
            esac
        }
        expected="$(code_directory_hash original)"
        actual="$(code_directory_hash "$2")"
        [ "$actual" = "$expected" ]
        """#
        for (target, status) in [("original", Int32(0)), ("different", 1), ("missing", 65), ("failure", 42)] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script, "test", helper.path, target]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, status, target)
        }
    }

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
