import Foundation
import XCTest
@testable import PoorMansTextAppSupport

final class PandocInstallerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextPandocInstallerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // Legt ein ausführbares Shell-Skript an, das in Tests die Rolle von
    // `brew` übernimmt.
    private func makeExecutable(named name: String, script: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testResolveHomebrewReturnsFirstExecutableCandidate() throws {
        let missing = temporaryDirectory.appendingPathComponent("missing/brew")
        let plainFile = temporaryDirectory.appendingPathComponent("plain-brew")
        try Data("not executable".utf8).write(to: plainFile)
        let executable = try makeExecutable(named: "brew", script: "#!/bin/sh\nexit 0\n")

        XCTAssertEqual(
            PandocInstaller.resolveHomebrew(candidates: [missing, plainFile, executable]),
            executable
        )
        XCTAssertNil(PandocInstaller.resolveHomebrew(candidates: [missing, plainFile]))
    }

    func testOfferOnlyAppearsWhilePandocIsMissingAndNotDeclined() {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

        XCTAssertNil(PandocInstaller.offer(
            pandocIsAvailable: true, installDeclined: false, brewExecutable: brew
        ))
        XCTAssertNil(PandocInstaller.offer(
            pandocIsAvailable: false, installDeclined: true, brewExecutable: brew
        ))
        XCTAssertEqual(
            PandocInstaller.offer(
                pandocIsAvailable: false, installDeclined: false, brewExecutable: brew
            ),
            .homebrewInstall(brewExecutable: brew)
        )
        XCTAssertEqual(
            PandocInstaller.offer(
                pandocIsAvailable: false, installDeclined: false, brewExecutable: nil
            ),
            .manualGuidance
        )
    }

    func testInstallRunsBrewInstallPandocAndSurvivesLargeErrorOutput() throws {
        let recordURL = temporaryDirectory.appendingPathComponent("arguments.txt")
        // 200.000 Zeichen auf stderr sind ein Mehrfaches des Pipe-Puffers
        // (64 KiB): Ohne das Leeren der Pipe vor `waitUntilExit()` bliebe
        // dieser Test für immer hängen.
        let brew = try makeExecutable(named: "brew", script: """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(recordURL.path)'
        head -c 200000 /dev/zero | tr '\\0' 'x' >&2
        exit 0
        """)

        try PandocInstaller.installPandoc(brewExecutable: brew) { true }

        XCTAssertEqual(
            try String(contentsOf: recordURL, encoding: .utf8),
            "install\npandoc\n"
        )
    }

    func testInstallReportsBrewErrorOutput() throws {
        let brew = try makeExecutable(named: "brew", script: """
        #!/bin/sh
        echo 'Error: pandoc bottle unavailable' >&2
        exit 1
        """)

        XCTAssertThrowsError(
            try PandocInstaller.installPandoc(brewExecutable: brew) { true }
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("Error: pandoc bottle unavailable"),
                "unexpected message: \(error.localizedDescription)"
            )
        }
    }

    func testInstallFailsWhenPandocRemainsUnavailable() throws {
        let brew = try makeExecutable(named: "brew", script: "#!/bin/sh\nexit 0\n")

        XCTAssertThrowsError(
            try PandocInstaller.installPandoc(brewExecutable: brew) { false }
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("still cannot be found"),
                "unexpected message: \(error.localizedDescription)"
            )
        }
    }
}
