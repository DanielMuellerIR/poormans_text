import Foundation
import XCTest

/// Die Wahl des CLI-Zielverzeichnisses hängt allein am PATH. Ein abschließender
/// Schrägstrich ist dort bedeutungslos, ein roher Zeichenkettenvergleich sah aber
/// einen Unterschied — und der Installer landete beim falschen Präfix oder brach
/// mit Exit 64 ab.
final class CLITargetDirectoryTests: XCTestCase {
    func testPathComparisonIgnoresMeaninglessSlashes() throws {
        let output = try runHelper(path: "/opt/homebrew/bin/:/usr/bin:/bin")

        XCTAssertEqual(output["member"], "yes")
        // Der frühere rohe Vergleich; er dokumentiert hier den Fehlerfall.
        XCTAssertEqual(output["raw"], "no")
        // Auf einem Rechner ohne installierte CLI wäre das vorher
        // `/usr/local/bin` gewesen.
        XCTAssertEqual(output["default"], "/opt/homebrew/bin")
        XCTAssertEqual(output["normalized"], "/usr/local/bin")
        XCTAssertEqual(output["root"], "/")
    }

    func testADirectoryOutsideThePathIsStillRejected() throws {
        let output = try runHelper(path: "/usr/bin:/bin")

        XCTAssertEqual(output["member"], "no")
        XCTAssertEqual(output["default"], "/usr/local/bin")
    }

    private func runHelper(path: String) throws -> [String: String] {
        let helperURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/cli_target.sh")
        let script = #"""
        set -euo pipefail
        source "$1"
        export PATH="$2"
        printf 'default=%s\n' "$(poormans_text_default_cli_directory)"
        if poormans_text_path_contains_directory /opt/homebrew/bin; then
            printf 'member=yes\n'
        else
            printf 'member=no\n'
        fi
        case ":$PATH:" in
            *":/opt/homebrew/bin:"*) printf 'raw=yes\n' ;;
            *) printf 'raw=no\n' ;;
        esac
        printf 'normalized=%s\n' "$(poormans_text_normalize_path '/usr//local/bin/')"
        printf 'root=%s\n' "$(poormans_text_normalize_path '/')"
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "cli-target-test", helperURL.path, path]
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
        XCTAssertEqual(process.terminationStatus, 0, errorText)

        var values = [String: String]()
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
