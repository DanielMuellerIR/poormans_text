import Foundation
import XCTest
@testable import PoorMansTextCore

/// Regressionstests zu den Funden der CodeQA-Kampagne vom 2026-08-29.
final class ReviewFixes20260829Tests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextReviewFixes0829-\(UUID().uuidString)",
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

    // MARK: - Eine Signaturprüfung liest nur den Dateikopf

    /// Die XLS-Erkennung las seit dem SIGBUS-Fix jede Nicht-ZIP-Datei
    /// vollständig in den Speicher — auch ein großes PDF oder Video, das
    /// niemals ein Compound-Dokument sein kann. Gemessen an einer 512-MB-Datei
    /// waren das 549 MB Spitzenspeicher statt 13 MB.
    func testPrefixStopsAfterTheRequestedBytes() throws {
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

    // MARK: - Auch die PDF-Erkennung öffnet über einen geprüften Deskriptor

    /// Die PDF-Signaturprüfung war die letzte Stelle, die eine fremde Quelle mit
    /// `FileHandle` ohne `O_NONBLOCK` öffnete. Auf eine FIFO ohne Schreiber
    /// kehrt ein solches `open` NIE zurück. Der zentrale Vorfilter in
    /// `DocumentConverter` fängt eine FIFO zwar ab, doch der Adapter darf sich
    /// darauf nicht verlassen — er wird auch direkt aufgerufen. Ohne den Fix
    /// läuft dieser Test nicht durch, sondern gar nicht mehr zu Ende.
    func testPDFDetectionRejectsAFIFOInsteadOfWaitingForAWriter() throws {
        let source = temporaryDirectory.appendingPathComponent("rohr.pdf")
        guard mkfifo(source.path, 0o600) == 0 else {
            throw XCTSkip("FIFO konnte nicht angelegt werden: \(String(cString: strerror(errno)))")
        }

        let detection = try PDFAdapter().inspectInput(at: source)
        guard case .invalid(_, _, let reason) = detection else {
            return XCTFail("Unerwartetes Ergebnis: \(detection)")
        }
        XCTAssertTrue(reason.contains("regular file"), reason)
    }

    // MARK: - Die Diagnose nennt das fehlende OLE-Kopfstück

    /// Eine `.xls`-Datei ohne OLE-Kopf wurde mit „the ZIP package signature is
    /// missing" abgelehnt. Bei einem XLS ist eine ZIP-Signatur aber gar nicht
    /// zu erwarten; die Meldung schickte den Nutzer in die falsche Richtung.
    func testXLSWithoutAnOLEHeaderNamesTheOLEHeader() throws {
        let source = temporaryDirectory.appendingPathComponent("Kein-OLE.xls")
        try Data("this is plain text, not a compound document".utf8).write(to: source)

        XCTAssertThrowsError(try DocumentConverter().inspect(source)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("OLE compound-document header"),
                error.localizedDescription
            )
        }
    }
}
