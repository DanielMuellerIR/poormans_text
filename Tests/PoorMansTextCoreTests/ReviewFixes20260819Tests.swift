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

    /// Die Erkennung öffnet die Eingabe als Erstes. Eine FIFO mit einer bekannten
    /// Endung ließ sie deshalb schon vor dem Staging ohne Zeitgrenze stehen —
    /// gefunden beim Prüfen des Staging-Fundes. Auch dieser Test läuft ohne den
    /// Fix nicht durch, sondern gar nicht mehr zu Ende.
    func testDetectionRejectsAFIFOBeforeAnyAdapterOpensIt() throws {
        let source = temporaryDirectory.appendingPathComponent("probe.docx")
        guard mkfifo(source.path, 0o600) == 0 else {
            throw XCTSkip("FIFO konnte nicht angelegt werden: \(String(cString: strerror(errno)))")
        }

        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: source)) { error in
            guard case ConversionError.unsupportedInput = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }
    }

    // MARK: - Archivprüfung und Archivbytes gehören zu einem Deskriptor

    /// Die Größengrenze wird jetzt über `fstat` auf demselben Deskriptor geprüft,
    /// aus dem auch gelesen wird. Die Testdatei ist dünn belegt: Sie meldet mehr
    /// als 1 GiB, belegt aber fast keinen Platz.
    func testArchiveReadingStillRejectsASourceBeyondTheArchiveBudget() throws {
        let source = temporaryDirectory.appendingPathComponent("riesig.docx")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 1_073_741_825)
        try handle.close()

        XCTAssertThrowsError(
            try ZIPArchiveInspector.packageContents(at: source, entryNames: ["mimetype"])
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("archive-size limit"),
                "Unerwarteter Fehler: \(error.localizedDescription)"
            )
        }
    }

    /// Gegenprobe: Ein Verweis auf ein gültiges Paket bleibt lesbar. `open` folgt
    /// ihm, und `fstat` beschreibt danach die Datei dahinter — nicht den Verweis.
    func testArchiveReadingStillFollowsASymbolicLinkToARegularPackage() throws {
        let original = temporaryDirectory.appendingPathComponent("Original.odt")
        try ZIPFixtureBuilder.odtPackage(
            contentXML: "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\"/>"
        ).write(to: original)
        let linkURL = temporaryDirectory.appendingPathComponent("Verweis.odt")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: original)

        let package = try ZIPArchiveInspector.packageContents(
            at: linkURL,
            entryNames: ["mimetype"]
        )

        XCTAssertEqual(
            package.entries["mimetype"].map { String(decoding: $0, as: UTF8.self) },
            "application/vnd.oasis.opendocument.text"
        )
    }
}
