import Foundation
import XCTest
@testable import PoorMansTextCore

final class FormatDetectionRegressionTests: XCTestCase {
    /// Die Erkennung öffnet die Eingabe als Erstes. Eine FIFO mit einer bekannten
    /// Endung ließ sie deshalb schon vor dem Staging ohne Zeitgrenze stehen —
    /// gefunden beim Prüfen des Staging-Fundes. Auch dieser Test läuft ohne den
    /// Fix nicht durch, sondern gar nicht mehr zu Ende.
    func testDetectionRejectsAFIFOBeforeAnyAdapterOpensIt() throws {
        let temporaryDirectory = try makeRegressionDirectory()
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

    /// Die PDF-Signaturprüfung war die letzte Stelle, die eine fremde Quelle mit
    /// `FileHandle` ohne `O_NONBLOCK` öffnete. Auf eine FIFO ohne Schreiber
    /// kehrt ein solches `open` NIE zurück. Der zentrale Vorfilter in
    /// `DocumentConverter` fängt eine FIFO zwar ab, doch der Adapter darf sich
    /// darauf nicht verlassen — er wird auch direkt aufgerufen. Ohne den Fix
    /// läuft dieser Test nicht durch, sondern gar nicht mehr zu Ende.
    func testPDFDetectionRejectsAFIFOInsteadOfWaitingForAWriter() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("rohr.pdf")
        guard mkfifo(source.path, 0o600) == 0 else {
            throw XCTSkip("FIFO konnte nicht angelegt werden: \(String(cString: strerror(errno)))")
        }

        #if os(Linux)
        let adapter = LinuxPDFAdapter()
        #else
        let adapter = PDFAdapter()
        #endif
        let detection = try adapter.inspectInput(at: source)
        guard case .invalid(_, _, let reason) = detection else {
            return XCTFail("Unerwartetes Ergebnis: \(detection)")
        }
        XCTAssertTrue(reason.contains("regular file"), reason)
    }

    /// Eine `.xls`-Datei ohne OLE-Kopf wurde mit „the ZIP package signature is
    /// missing" abgelehnt. Bei einem XLS ist eine ZIP-Signatur aber gar nicht
    /// zu erwarten; die Meldung schickte den Nutzer in die falsche Richtung.
    func testXLSWithoutAnOLEHeaderNamesTheOLEHeader() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("Kein-OLE.xls")
        try Data("this is plain text, not a compound document".utf8).write(to: source)

        XCTAssertThrowsError(try DocumentConverter().inspect(source)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("OLE compound-document header"),
                error.localizedDescription
            )
        }
    }

    func testLegacyWordDetectionRejectsOversizedInput() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("Oversized.doc")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]).write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 1_073_741_825)
        try handle.close()

        #if os(Linux)
        let adapter = LinuxLegacyWordAdapter()
        #else
        let adapter = LegacyWordAdapter()
        #endif
        let detection = try adapter.inspectInput(at: source)
        guard case .invalid(.doc, _, let reason) = detection else {
            return XCTFail("Unexpected detection: \(detection)")
        }
        XCTAssertTrue(reason.contains("size limit"), reason)
    }

    /// `inspect` und `detectFormat` banden keinen Ausführungskontext. Damit lief
    /// jeder Werkzeugstart der Erkennung ohne Zeitgrenze und ohne erreichbaren
    /// Abbruch-Token.
    func testInspectAndDetectFormatHonourACancellationToken() throws {
        let root = try makeRegressionDirectory()
        let sourceURL = root.appendingPathComponent("Tabelle.ods")
        try RegressionFixtures.ods(meta: "<dc:title>Titel</dc:title>").write(to: sourceURL)
        let token = ConversionCancellationToken()
        token.cancel()

        XCTAssertThrowsError(try DocumentConverter().inspect(sourceURL, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else {
                return XCTFail("unerwarteter Fehler: \(error)")
            }
        }
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: sourceURL, cancellation: token)) { error in
            guard case ConversionError.cancelled = error else {
                return XCTFail("unerwarteter Fehler: \(error)")
            }
        }
        // Ohne Token bleibt die Erkennung unverändert erfolgreich.
        XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), .ods)
    }
}
