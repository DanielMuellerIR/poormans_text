import Foundation
import XCTest
@testable import PoorMansTextCore

final class VerifiedFileStagingRegressionTests: XCTestCase {
    func testStagingRejectsASourceThatExceedsTheBudget() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("gross.bin")
        try Data(repeating: 0x41, count: 4096).write(to: source)
        let destination = temporaryDirectory.appendingPathComponent("staged.bin")

        XCTAssertThrowsError(
            try VerifiedFileStaging.stage(
                from: source,
                to: destination,
                maximumBytes: 1024,
                describedAs: "the source"
            )
        )
        // Kein halbfertiger Rest: Das Budget wird vor dem ersten Schreiben geprüft.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testStagingRejectsADirectoryInsteadOfCopyingIt() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("ordner", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let destination = temporaryDirectory.appendingPathComponent("staged-dir")

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
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testStagingNeverOverwritesAnExistingDestination() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("quelle.bin")
        try Data("neu".utf8).write(to: source)
        let destination = temporaryDirectory.appendingPathComponent("staged.bin")
        try Data("bestehend".utf8).write(to: destination)

        XCTAssertThrowsError(
            try VerifiedFileStaging.stage(
                from: source,
                to: destination,
                maximumBytes: 1_048_576,
                describedAs: "the source"
            )
        )
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "bestehend")
    }

    func testStagingCopiesAValidSourceCompletely() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let payload = Data(repeating: 0x5A, count: 300_000)   // größer als ein Lesepuffer
        let source = temporaryDirectory.appendingPathComponent("quelle.bin")
        try payload.write(to: source)
        let destination = temporaryDirectory.appendingPathComponent("staged.bin")

        let copied = try VerifiedFileStaging.stage(
            from: source,
            to: destination,
            maximumBytes: 1_048_576,
            describedAs: "the source"
        )

        XCTAssertEqual(copied, payload.count)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    /// Eine FIFO ohne Schreiber ließ `open(… O_RDONLY)` unbegrenzt warten. Der
    /// Test läuft ohne den Fix nicht durch, sondern gar nicht mehr zu Ende.
    func testStagingRejectsAFIFOInsteadOfWaitingForAWriter() throws {
        let temporaryDirectory = try makeRegressionDirectory()
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

    /// Die XLS-Erkennung bildete eine fremde Datei bis 1 GiB mit
    /// `.mappedIfSafe` ab. Kürzt ein Abgleichdienst sie danach, beendet SIGBUS
    /// den ganzen Prozess — kein `catch` fängt das ab. Gelesen wird jetzt über
    /// genau einen Deskriptor, ohne Abbildung.
    func testVerifiedReadReturnsTheContentsWithoutMapping() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("quelle.bin")
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        try payload.write(to: source)

        let gelesen = try VerifiedFileStaging.contents(
            of: source,
            maximumBytes: 1_048_576,
            describedAs: "the test source"
        )
        XCTAssertEqual(gelesen, payload)
    }

    func testVerifiedReadRejectsASourceAboveTheBudget() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("zu-gross.bin")
        try Data(repeating: 0x41, count: 2048).write(to: source)

        XCTAssertThrowsError(
            try VerifiedFileStaging.contents(
                of: source,
                maximumBytes: 1024,
                describedAs: "the test source"
            )
        ) { error in
            guard let staging = error as? VerifiedFileStaging.StagingError else {
                return XCTFail("Erwartet wird ein StagingError, nicht \(error)")
            }
            XCTAssertEqual(staging.kind, .source)
        }
    }

    func testVerifiedReadRejectsADirectory() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        XCTAssertThrowsError(
            try VerifiedFileStaging.contents(
                of: temporaryDirectory,
                maximumBytes: 1_048_576,
                describedAs: "the test source"
            )
        )
    }

    /// Die XLS-Erkennung las seit dem SIGBUS-Fix jede Nicht-ZIP-Datei
    /// vollständig in den Speicher — auch ein großes PDF oder Video, das
    /// niemals ein Compound-Dokument sein kann. Gemessen an einer 512-MB-Datei
    /// waren das 549 MB Spitzenspeicher statt 13 MB.
    func testPrefixStopsAfterTheRequestedBytes() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("gross.bin")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try payload.write(to: source)

        let header = try VerifiedFileStaging.prefix(
            of: source,
            maximumBytes: 1_048_576,
            prefixBytes: 8,
            describedAs: "the test source"
        )

        XCTAssertEqual(header, payload.prefix(8))
    }

    /// Ist die Datei kürzer als der angeforderte Kopf, kommt eben weniger
    /// zurück — das ist kein Fehler, sondern die Antwort „passt nicht".
    func testPrefixReturnsAShortFileCompletely() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("kurz.bin")
        try Data([0xD0, 0xCF]).write(to: source)

        let header = try VerifiedFileStaging.prefix(
            of: source,
            maximumBytes: 1_048_576,
            prefixBytes: 8,
            describedAs: "the test source"
        )

        XCTAssertEqual(header, Data([0xD0, 0xCF]))
        XCTAssertFalse(LegacyXLSWorkbookParser.hasCompoundDocumentSignature(header))
    }

    func testPrivateFileCopyKeepsTheVerifiedBytesAfterTheSourceIsReplaced() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        try Data("first".utf8).write(to: source)

        let snapshotText = try VerifiedFileStaging.withTemporaryCopy(
            of: source,
            maximumBytes: 100,
            describedAs: "the test source",
            fileExtension: "pdf"
        ) { snapshot in
            try FileManager.default.removeItem(at: source)
            try Data("second".utf8).write(to: source)
            return try String(contentsOf: snapshot, encoding: .utf8)
        }

        XCTAssertEqual(snapshotText, "first")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "second")
    }
}
