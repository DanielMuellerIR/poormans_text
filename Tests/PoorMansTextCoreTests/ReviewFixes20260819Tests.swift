import Foundation
import XCTest
@testable import PoorMansTextCore

/// Regressionstests zu den Funden des Nacht-Reviews vom 2026-08-19.
final class ReviewFixes20260819Tests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextReviewFixes0819-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Staging hängt sich an einer FIFO nicht auf

    /// Eine FIFO ohne Schreiber ließ `open(… O_RDONLY)` unbegrenzt warten. Der
    /// Test läuft ohne den Fix nicht durch, sondern gar nicht mehr zu Ende.
    func testStagingRejectsAFIFOInsteadOfWaitingForAWriter() throws {
        let source = temporaryDirectory.appendingPathComponent("rohr")
        guard mkfifo(source.path, 0o600) == 0 else {
            throw XCTSkip("FIFO konnte nicht angelegt werden: \(String(cString: strerror(errno)))")
        }
        let destination = temporaryDirectory.appendingPathComponent("staged.bin")

        XCTAssertThrowsError(
            try VerifiedFileStaging.stage(
                from: source,
                to: destination,
                maximumBytes: 1_048_576,
                describedAs: "the source"
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("regular file"),
                "Unerwarteter Fehler: \(error.localizedDescription)"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
