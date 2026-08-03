import Foundation
import XCTest

/// Die Root-Wrapper stellen ihre Vorgabe voran und reichen die Nutzerargumente
/// dahinter durch. Ein vollständiges Release braucht beides in einem Lauf:
/// `scripts/verify_release.sh` vergleicht die CodeDirectory-Hashes von Repo-App,
/// installierter App und der App im DMG, und zwei getrennte Läufe bauen und
/// signieren zweimal.
final class InstallModeTests: XCTestCase {
    func testTheInstallWrapperBuildsNoDMG() throws {
        let modes = try runParser(["--no-dmg"])

        XCTAssertEqual(modes["status"], "0")
        XCTAssertEqual(modes["notarize"], "1")
        XCTAssertEqual(modes["make_dmg"], "0")
        XCTAssertEqual(modes["do_install"], "1")
    }

    func testTheReleaseWrapperInstallsNothing() throws {
        let modes = try runParser(["--no-install"])

        XCTAssertEqual(modes["status"], "0")
        XCTAssertEqual(modes["make_dmg"], "1")
        XCTAssertEqual(modes["do_install"], "0")
    }

    /// `./install.sh --with-dmg` — die Reihenfolge entscheidet, das Nutzerflag
    /// hebt die Vorgabe des Wrappers auf.
    func testWithDMGOverridesTheWrapperDefaultAndKeepsTheInstallation() throws {
        let modes = try runParser(["--no-dmg", "--with-dmg"])

        XCTAssertEqual(modes["status"], "0")
        XCTAssertEqual(modes["make_dmg"], "1")
        XCTAssertEqual(modes["do_install"], "1")
    }

    /// `./install.sh --with-dmg --no-notarize`: ohne Ticket endet der Lauf nach
    /// Build und Signatur, ein DMG entsteht dabei nicht.
    func testWithoutNotarizationTheRunStaysLocal() throws {
        let modes = try runParser(["--no-dmg", "--with-dmg", "--no-notarize"])

        XCTAssertEqual(modes["status"], "0")
        XCTAssertEqual(modes["notarize"], "0")
    }

    func testARunWithoutDMGAndWithoutInstallationIsRejected() throws {
        let modes = try runParser(["--no-dmg", "--no-install"])

        XCTAssertEqual(modes["status"], "64")
        XCTAssertTrue(modes["stderr", default: ""].contains("ergeben keinen Lauf"))
    }

    func testAnUnknownOptionIsRejected() throws {
        let modes = try runParser(["--no-dmg", "--with-dmg=yes"])

        XCTAssertEqual(modes["status"], "64")
        XCTAssertTrue(modes["stderr", default: ""].contains("Aufruf:"))
    }

    private func runParser(_ arguments: [String]) throws -> [String: String] {
        let helperURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/install_modes.sh")
        let script = #"""
        set -uo pipefail
        source "$1"
        shift
        poormans_text_parse_install_modes "$@"
        status=$?
        printf 'status=%s\n' "$status"
        printf 'notarize=%s\n' "$notarize"
        printf 'make_dmg=%s\n' "$make_dmg"
        printf 'do_install=%s\n' "$do_install"
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "install-mode-test", helperURL.path] + arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        process.waitUntilExit()

        var values = ["stderr": errorText]
        for line in String(decoding: outputData, as: UTF8.self).split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            values[String(line[line.startIndex..<separator])]
                = String(line[line.index(after: separator)...])
        }
        return values
    }
}
