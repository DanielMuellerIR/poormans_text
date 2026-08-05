import Foundation
import XCTest

final class InstallScriptRollbackTests: XCTestCase {
    func testFailedRollbackKeepsPreviousAppAtReportedRescuePath() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=swapped
            created_cli=0
            swap_install_paths() { return 1; }
            remove_install_path() { echo "unexpected remove: $1" >&2; return 99; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            first_status=$?
            poormans_text_cleanup_installation
            second_status=$?
            echo "$first_status:$second_status"
            exit "$second_status"
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 74)
            XCTAssertEqual(result.standardOutput, "74:74\n")
            XCTAssertTrue(result.standardError.contains(stagedApp.path))
            XCTAssertFalse(result.standardError.contains("unexpected remove"))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: stagedApp.appendingPathComponent("old-marker").path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destinationApp.appendingPathComponent("new-marker").path
            ))
        }
    }

    func testSuccessfulRollbackRestoresPreviousAppBeforeRemovingNewApp() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=swapped
            created_cli=0
            swap_install_paths() {
                temporary="$1.swap"
                /bin/mv "$1" "$temporary"
                /bin/mv "$2" "$1"
                /bin/mv "$temporary" "$2"
            }
            remove_install_path() { /bin/mv "$1" "$1.removed"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destinationApp.appendingPathComponent("old-marker").path
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.path))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: stagedApp.path + ".removed")
                    .appendingPathComponent("new-marker").path
            ))
        }
    }

    func testSuspiciousBackupDoesNotReplaceValidatedNewApp() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=backup-suspicious
            created_cli=0
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { echo "unexpected remove: $1" >&2; return 99; }
            app_matches_release_identity() { return 1; }
            poormans_text_cleanup_installation
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertFalse(result.standardError.contains("unexpected"))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: stagedApp.appendingPathComponent("old-marker").path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destinationApp.appendingPathComponent("new-marker").path
            ))
        }
    }

    private func withTransactionDirectories(
        _ body: (URL, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextInstallRollbackTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedApp = root.appendingPathComponent("staged.app", isDirectory: true)
        let destinationApp = root.appendingPathComponent("destination.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationApp, withIntermediateDirectories: true)
        try Data().write(to: stagedApp.appendingPathComponent("old-marker"))
        try Data().write(to: destinationApp.appendingPathComponent("new-marker"))
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try body(stagedApp, destinationApp)
    }

    private func runBash(
        _ script: String,
        stagedApp: URL,
        destinationApp: URL
    ) throws -> ProcessResult {
        let helperURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/install_transaction.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c", script, "rollback-test", helperURL.path, stagedApp.path, destinationApp.path,
        ]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            standardError: String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    private struct ProcessResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }
}
