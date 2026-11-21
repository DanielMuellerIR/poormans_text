import Foundation
import XCTest
@testable import PoorMansTextCore

final class ZIPInspectionRegressionTests: XCTestCase {
    /// Die Größengrenze wird jetzt über `fstat` auf demselben Deskriptor geprüft,
    /// aus dem auch gelesen wird. Die Testdatei ist dünn belegt: Sie meldet mehr
    /// als 1 GiB, belegt aber fast keinen Platz.
    func testArchiveReadingStillRejectsASourceBeyondTheArchiveBudget() throws {
        let temporaryDirectory = try makeRegressionDirectory()
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
        let temporaryDirectory = try makeRegressionDirectory()
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

    /// Derselbe Name mehrfach angefordert wird nur EINMAL entpackt; das Ergebnis
    /// bleibt unverändert.
    func testPackageContentsUnpacksARepeatedEntryNameOnlyOnce() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let sourceURL = temporaryDirectory.appendingPathComponent("Wiederholt.odt")
        try ZIPFixtureBuilder.odtPackage(
            contentXML: "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\"/>"
        ).write(to: sourceURL)

        let package = try ZIPArchiveInspector.packageContents(
            at: sourceURL,
            entryNames: ["mimetype", "mimetype", "mimetype"]
        )

        XCTAssertEqual(package.entries.count, 1)
        XCTAssertEqual(
            package.entries["mimetype"].map { String(decoding: $0, as: UTF8.self) },
            "application/vnd.oasis.opendocument.text"
        )
    }

    /// `looksLikeZIP` öffnete blockierend. Eine FIFO ohne Schreiber ließ die
    /// Erkennung deshalb ohne Zeitgrenze stehen; ohne den Fix läuft dieser Test
    /// nicht durch, sondern gar nicht mehr zu Ende.
    func testZIPSignatureCheckRejectsAFIFOInsteadOfWaitingForAWriter() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("rohr.odt")
        guard mkfifo(source.path, 0o600) == 0 else {
            throw XCTSkip("FIFO konnte nicht angelegt werden: \(String(cString: strerror(errno)))")
        }

        XCTAssertFalse(try ZIPArchiveInspector.looksLikeZIP(at: source))
    }

    /// Ein veraltetes erstes `0x7075`-Feld beendete die Suche. Ein zweites,
    /// gültiges Feld — hier mit einem Traversal-Namen — blieb dahinter
    /// unbemerkt.
    func testArchiveRejectsASecondUnicodePathFieldBehindAnOutdatedOne() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let rawName = Data("mimetype".utf8)
        var extraField = ZIPFixtureBuilder.unicodePathField(
            name: "harmlos.xml",
            rawName: Data("ein anderer Name".utf8)      // falsche Prüfsumme: veraltet
        )
        extraField.append(
            ZIPFixtureBuilder.unicodePathField(name: "../ausbruch.xml", rawName: rawName)
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("Zwei.odt")
        try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "mimetype",
                content: Data("application/vnd.oasis.opendocument.text".utf8),
                isStored: true,
                centralExtraFieldBytes: extraField
            ),
        ]).write(to: sourceURL)

        XCTAssertThrowsError(
            try ZIPArchiveInspector.packageContents(at: sourceURL, entryNames: ["mimetype"])
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("more than one Unicode path field"),
                "Unerwarteter Fehler: \(error.localizedDescription)"
            )
        }
    }

    /// Ein Extrafeld ist eine lückenlose Folge. Bleiben Bytes übrig, liest ein
    /// anderer Entpacker sie womöglich anders.
    func testArchiveRejectsAnExtraFieldWithLeftoverBytes() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        var extraField = ZIPFixtureBuilder.unicodePathField(
            name: "mimetype",
            rawName: Data("mimetype".utf8)
        )
        extraField.append(contentsOf: [0x70, 0x75])      // angefangene, unvollständige Kennung
        let sourceURL = temporaryDirectory.appendingPathComponent("Rest.odt")
        try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "mimetype",
                content: Data("application/vnd.oasis.opendocument.text".utf8),
                isStored: true,
                centralExtraFieldBytes: extraField
            ),
        ]).write(to: sourceURL)

        XCTAssertThrowsError(
            try ZIPArchiveInspector.packageContents(at: sourceURL, entryNames: ["mimetype"])
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("malformed extra field"),
                "Unerwarteter Fehler: \(error.localizedDescription)"
            )
        }
    }

    func testCompressedZIPMetadataIsBoundedBeforeItsInputSlice() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let archiveURL = temporaryDirectory.appendingPathComponent("metadata.zip")
        let archive = try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "mimetype",
                content: Data("x".utf8),
                declaredUncompressedSize: 1,
                declaredCompressedSize: 16_777_217,
                isStored: true
            ),
        ])
        try archive.write(to: archiveURL)

        XCTAssertThrowsError(
            try ZIPArchiveInspector.packageContents(at: archiveURL, entryNames: ["mimetype"])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("compressed package metadata"))
        }
    }
}
