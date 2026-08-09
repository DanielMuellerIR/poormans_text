import Foundation
import XCTest

final class InstallScriptRollbackTests: XCTestCase {
    func testSignalBeforeSwapLeavesPreviousAppAndRemovesStagedApp() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=swap-pending
            had_existing_app=1
            created_cli=0
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$staged_app")"
            old_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { /bin/rm -rf "$1"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.path))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destinationApp.appendingPathComponent("new-marker").path
            ))
            XCTAssertFalse(result.standardError.contains("unexpected"))
        }
    }

    func testSignalAfterSwapButBeforeStateAssignmentRestoresPreviousApp() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=swap-pending
            had_existing_app=1
            created_cli=0
            old_app_identity="$(/usr/bin/stat -f '%d:%i' "$staged_app")"
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
            swap_install_paths() {
                temporary="$1.swap"
                /bin/mv "$1" "$temporary"
                /bin/mv "$2" "$1"
                /bin/mv "$temporary" "$2"
            }
            remove_install_path() { /bin/rm -rf "$1"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destinationApp.appendingPathComponent("old-marker").path
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.path))
        }
    }

    func testSignalAfterFirstInstallMoveButBeforeStateAssignmentRemovesNewApp() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            try FileManager.default.removeItem(at: destinationApp)
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=install-pending
            had_existing_app=0
            created_cli=0
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$staged_app")"
            old_app_identity=""
            /bin/mv "$staged_app" "$destination_app"
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { /bin/rm -rf "$1"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationApp.path))
            XCTAssertFalse(result.standardError.contains("unexpected"))
        }
    }

    func testSignalBeforeFirstInstallMoveRemovesOnlyStagedApp() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            try FileManager.default.removeItem(at: destinationApp)
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=install-pending
            had_existing_app=0
            created_cli=0
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$staged_app")"
            old_app_identity=""
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { /bin/rm -rf "$1"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationApp.path))
            XCTAssertFalse(result.standardError.contains("unexpected"))
        }
    }

    func testSignalAfterCLILinkButBeforeCommandReturnsRemovesOnlyCreatedLink() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=installed-new
            had_existing_app=0
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
            old_app_identity=""
            created_cli=1
            destination_cli="$2.cli"
            staged_cli="$2.cli-stage"
            installed_cli="$3/Contents/Resources/poormans-text"
            ln -s "$installed_cli" "$destination_cli"
            new_cli_identity="$(/usr/bin/stat -f '%d:%i' "$destination_cli")"
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { /bin/rm -rf "$1"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.path + ".cli"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationApp.path))
            XCTAssertFalse(result.standardError.contains("unexpected"))
        }
    }

    func testCleanupNeverRemovesAReplacementCLILinkWithTheSameTarget() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=installed-new
            had_existing_app=0
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
            old_app_identity=""
            created_cli=1
            destination_cli="$2.cli"
            staged_cli="$2.cli-stage"
            installed_cli="$3/Contents/Resources/poormans-text"
            ln -s "$installed_cli" "$destination_cli"
            new_cli_identity="$(/usr/bin/stat -f '%d:%i' "$destination_cli")"
            /bin/mv "$destination_cli" "$destination_cli.owned"
            ln -s "$installed_cli" "$destination_cli"
            foreign_identity="$(/usr/bin/stat -f '%d:%i' "$destination_cli")"
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { /bin/rm -rf "$1"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            status=$?
            printf '%s:%s:%s\n' "$status" \
                "$(/usr/bin/stat -f '%d:%i' "$destination_cli")" \
                "$(readlink "$destination_cli")"
            printf 'foreign:%s\n' "$foreign_identity"
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0)
            let lines = result.standardOutput.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, 2, result.standardOutput)
            let expectedResult = "73:\(lines[1].dropFirst("foreign:".count)):\(destinationApp.path)/Contents/Resources/poormans-text"
            XCTAssertEqual(lines[0], expectedResult)
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: stagedApp.path + ".cli"
                ),
                destinationApp.path + "/Contents/Resources/poormans-text"
            )
        }
    }

    func testSignalAfterStagedCLILinkBeforeAtomicMoveRemovesOnlyStagedLink() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=installed-new
            had_existing_app=0
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
            old_app_identity=""
            created_cli=1
            destination_cli="$2.cli"
            staged_cli="$2.cli-stage"
            installed_cli="$3/Contents/Resources/poormans-text"
            ln -s "$installed_cli" "$staged_cli"
            new_cli_identity="$(/usr/bin/stat -f '%d:%i' "$staged_cli")"
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { /bin/rm -rf "$1"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.path + ".cli"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp.path + ".cli-stage"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationApp.path))
            XCTAssertFalse(result.standardError.contains("unexpected"))
        }
    }

    func testCLIPendingStateOwnsTheStagedLinkBeforeCreatedFlagAssignment() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=installed-new
            had_existing_app=0
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
            old_app_identity=""
            created_cli=0
            cli_state=stage-pending
            destination_cli="$2.cli"
            staged_cli="$2.cli-stage"
            installed_cli="$3/Contents/Resources/poormans-text"
            ln -s "$installed_cli" "$staged_cli"
            new_cli_identity="$(/usr/bin/stat -f '%d:%i' "$staged_cli")"
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { /bin/rm -rf "$1"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertThrowsError(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: stagedApp.path + ".cli-stage"
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationApp.path))
            XCTAssertFalse(result.standardError.contains("unexpected"))
        }
    }

    func testSignalAfterStagedLinkBeforeIdentityAssignmentDoesNotLeaveTheLink() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=installed-new
            had_existing_app=0
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
            old_app_identity=""
            created_cli=0
            cli_state=stage-pending
            destination_cli="$2.cli"
            staged_cli="$2.cli-stage"
            installed_cli="$3/Contents/Resources/poormans-text"
            new_cli_identity=""
            needs_admin=0
            signal_marker="$2.signal-sent"
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { /bin/rm -rf "$1"; }
            app_matches_release_identity() { return 0; }
            poormans_text_path_identity() {
                if [ ! -e "$signal_marker" ]; then
                    : > "$signal_marker"
                    kill -TERM "$$"
                fi
                /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null || true
            }
            trap 'poormans_text_cleanup_installation' EXIT
            cli_link_status=0
            poormans_text_create_staged_cli_link_with_deferred_signals \
                || cli_link_status=$?
            exit "$cli_link_status"
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 143, result.standardError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationApp.path))
            XCTAssertThrowsError(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: stagedApp.path + ".cli-stage"
                )
            )
        }
    }

    func testAcceptedInstallationStatesNeverRemoveTheirOwnedCLILink() throws {
        for terminalState in ["published", "backup-suspicious", "committed"] {
            try withTransactionDirectories { stagedApp, destinationApp in
                let script = #"""
                source "$1"
                set -u
                staged_app="$2"
                destination_app="$3"
                installation_state="\#(terminalState)"
                had_existing_app=0
                new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
                old_app_identity=""
                created_cli=1
                cli_state=installed
                destination_cli="$2.cli"
                staged_cli="$2.cli-stage"
                installed_cli="$3/Contents/Resources/poormans-text"
                ln -s "$installed_cli" "$destination_cli"
                new_cli_identity="$(/usr/bin/stat -f '%d:%i' "$destination_cli")"
                swap_install_paths() { echo "unexpected swap" >&2; return 99; }
                remove_install_path() { /bin/rm -rf "$1"; }
                app_matches_release_identity() { return 0; }
                poormans_text_cleanup_installation
                printf '%s:%s\n' "$installation_state" "$(readlink "$destination_cli")"
                """#

                let result = try runBash(
                    script,
                    stagedApp: stagedApp,
                    destinationApp: destinationApp
                )

                XCTAssertEqual(result.status, 0, "\(terminalState): \(result.standardError)")
                XCTAssertEqual(
                    result.standardOutput,
                    "clean:\(destinationApp.path)/Contents/Resources/poormans-text\n",
                    terminalState
                )
            }
        }
    }

    func testInstallerRecordsTransitionStateBeforeEveryFilesystemMutation() throws {
        let installerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/install.sh")
        let installer = try String(contentsOf: installerURL, encoding: .utf8)

        XCTAssertSourceOrder(
            "installation_state=\"swap-pending\"",
            before: "swap_install_paths \"$staged_app\" \"$destination_app\"",
            in: installer
        )
        XCTAssertSourceOrder(
            "installation_state=\"install-pending\"",
            before: "move_install_path \"$staged_app\" \"$destination_app\"",
            in: installer
        )
        XCTAssertSourceOrder(
            "cli_state=\"stage-pending\"",
            before: "poormans_text_create_staged_cli_link_with_deferred_signals",
            in: installer
        )
        XCTAssertSourceOrder(
            "poormans_text_create_staged_cli_link_with_deferred_signals",
            before: "move_install_path \"$staged_cli\" \"$destination_cli\"",
            in: installer
        )
        XCTAssertSourceOrder(
            "created_cli=1",
            before: "move_install_path \"$staged_cli\" \"$destination_cli\"",
            in: installer
        )
        XCTAssertSourceOrder(
            "\"$staged_dmg\" \"$dmg\" || dmg_move_status=$?",
            before: "poormans_text_verify_or_discard_release_artifacts",
            in: installer
        )
    }

    func testStagedCLILinkCreationPropagatesLnFailure() throws {
        let transactionURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/install_transaction.sh")
        let transaction = try String(contentsOf: transactionURL, encoding: .utf8)

        XCTAssertTrue(transaction.contains("sudo ln -s \"$installed_cli\" \"$staged_cli\" || return 74"))
        XCTAssertTrue(transaction.contains("ln -s \"$installed_cli\" \"$staged_cli\" || return 74"))
    }

    func testMismatchedPublishedPairRemovesOnlyOwnedArtifact() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            dmg="$2/release.dmg"
            checksum="$2/release.dmg.sha256"
            printf owned-dmg > "$dmg"
            printf owned-checksum > "$checksum"
            dmg_identity="$(/usr/bin/stat -f '%d:%i' "$dmg")"
            checksum_identity="$(/usr/bin/stat -f '%d:%i' "$checksum")"
            /bin/mv "$checksum" "$checksum.owned"
            printf foreign-checksum > "$checksum"
            published_dmg=1
            published_checksum=1
            remove_exact_path() { /bin/rm -f "$1"; }
            poormans_text_verify_or_discard_release_artifacts
            status=$?
            printf '%s:%s:%s:%s\n' "$status" "$published_dmg" "$published_checksum" "$(cat "$checksum")"
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.standardOutput, "73:0:1:foreign-checksum\n")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: stagedApp.appendingPathComponent("release.dmg").path
            ))
        }
    }

    func testFailedRollbackKeepsPreviousAppAtReportedRescuePath() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=swapped
            old_app_identity="$(/usr/bin/stat -f '%d:%i' "$staged_app")"
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
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
            old_app_identity="$(/usr/bin/stat -f '%d:%i' "$staged_app")"
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
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

    func testPublishedDMGMarkerCommitsInstallationDuringSignalCleanup() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            staged_app="$2"
            destination_app="$3"
            installation_state=swapped
            had_existing_app=1
            old_app_identity="$(/usr/bin/stat -f '%d:%i' "$staged_app")"
            new_app_identity="$(/usr/bin/stat -f '%d:%i' "$destination_app")"
            created_cli=1
            make_dmg=1
            dmg="$2.dmg"
            checksum="$2.dmg.sha256"
            : > "$dmg"
            : > "$checksum"
            dmg_identity="$(/usr/bin/stat -f '%d:%i' "$dmg")"
            checksum_identity="$(/usr/bin/stat -f '%d:%i' "$checksum")"
            destination_cli="$2.cli"
            installed_cli="$3/Contents/Resources/poormans-text"
            ln -s "$installed_cli" "$destination_cli"
            swap_install_paths() { echo "unexpected swap" >&2; return 99; }
            remove_install_path() { /bin/mv "$1" "$1.removed"; }
            app_matches_release_identity() { return 0; }
            poormans_text_cleanup_installation
            printf '%s:%s\n' "$installation_state" "$(readlink "$destination_cli")"
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0, result.standardError)
            XCTAssertEqual(
                result.standardOutput,
                "clean:\(destinationApp.path)/Contents/Resources/poormans-text\n"
            )
            XCTAssertFalse(result.standardError.contains("unexpected"))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destinationApp.appendingPathComponent("new-marker").path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: stagedApp.path + ".removed")
                    .appendingPathComponent("old-marker").path
            ))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: stagedApp.path + ".cli"),
                destinationApp.path + "/Contents/Resources/poormans-text"
            )
        }
    }

    func testChangedPublishedChecksumIsNeverRemovedOrUntracked() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            checksum="$2/checksum"
            printf old > "$checksum"
            checksum_identity="$(/usr/bin/stat -f '%d:%i' "$checksum")"
            /bin/mv "$checksum" "$checksum.old"
            printf replacement > "$checksum"
            published_checksum=1
            remove_exact_path() { echo "unexpected remove" >&2; return 99; }
            poormans_text_discard_published_checksum
            status=$?
            printf '%s:%s:%s\n' "$status" "$published_checksum" "$(cat "$checksum")"
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.standardOutput, "73:1:replacement\n")
            XCTAssertTrue(result.standardError.contains("Identität geändert"))
            XCTAssertFalse(result.standardError.contains("unexpected remove"))
        }
    }

    func testFailedChecksumRemovalKeepsCleanupTrackingActive() throws {
        try withTransactionDirectories { stagedApp, destinationApp in
            let script = #"""
            source "$1"
            set -u
            checksum="$2/checksum"
            printf checksum > "$checksum"
            checksum_identity="$(/usr/bin/stat -f '%d:%i' "$checksum")"
            published_checksum=1
            remove_exact_path() { return 99; }
            poormans_text_discard_published_checksum
            status=$?
            printf '%s:%s:%s\n' "$status" "$published_checksum" "$(cat "$checksum")"
            """#

            let result = try runBash(script, stagedApp: stagedApp, destinationApp: destinationApp)

            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.standardOutput, "74:1:checksum\n")
            XCTAssertTrue(result.standardError.contains("konnte nicht entfernt werden"))
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

    private func XCTAssertSourceOrder(
        _ earlier: String,
        before later: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let earlierRange = source.range(of: earlier),
              let laterRange = source.range(of: later) else {
            XCTFail("Source markers are missing: \(earlier) / \(later)", file: file, line: line)
            return
        }
        XCTAssertLessThan(earlierRange.lowerBound, laterRange.lowerBound, file: file, line: line)
    }
}
