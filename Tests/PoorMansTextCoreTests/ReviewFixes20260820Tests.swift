import Foundation
import Darwin
import XCTest
@testable import PoorMansTextCore

/// Regressionstests zu den Funden des Nacht-Reviews vom 2026-08-20.
final class ReviewFixes20260820Tests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextReviewFixes0820-\(UUID().uuidString)",
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

    // MARK: - Eine Blattdatei gehört zu genau einem Blatt

    /// Zeigten mehrere Blätter auf dieselbe Blattdatei, wurde dieselbe XML
    /// mehrfach entpackt und mehrfach geparst — bei 256 erlaubten Blättern viel
    /// Arbeit aus einer winzigen Datei.
    func testWorkbookRejectsTwoSheetsPointingAtTheSameWorksheetPart() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Doppelt.xlsx")
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Summary" sheetId="1" r:id="rId1"/>
            <sheet name="Kopie" sheetId="2" r:id="rId1"/>
          </sheets>
        </workbook>
        """
        try ZIPFixtureBuilder.xlsxPackage(
            firstSheetXML: worksheetXML,
            secondSheetXML: worksheetXML,
            workbookOverride: workbook
        ).write(to: sourceURL)

        XCTAssertThrowsError(try XLSXWorkbookParser.parse(packageAt: sourceURL)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("same worksheet part"),
                "Unerwarteter Fehler: \(error.localizedDescription)"
            )
        }
    }

    /// Gegenprobe: Zwei eigene Blattdateien bleiben eine gültige Arbeitsmappe.
    func testWorkbookWithTwoDistinctWorksheetPartsStillParses() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Normal.xlsx")
        try ZIPFixtureBuilder.xlsxPackage(
            firstSheetXML: worksheetXML,
            secondSheetXML: worksheetXML
        ).write(to: sourceURL)

        let parsed = try XLSXWorkbookParser.parse(packageAt: sourceURL)

        XCTAssertEqual(parsed.sheets.count, 2)
    }

    /// Derselbe Name mehrfach angefordert wird nur EINMAL entpackt; das Ergebnis
    /// bleibt unverändert.
    func testPackageContentsUnpacksARepeatedEntryNameOnlyOnce() throws {
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

    // MARK: - Eine fremde Datei darf nie abgebildet werden

    /// Kürzt ein anderer Prozess eine abgebildete Datei, endet der nächste
    /// Zugriff hinter ihrem neuen Ende mit SIGBUS. Der Test läuft deshalb in
    /// einem eigenen XCTest-Prozess: Er dokumentiert den realen Absturz, ohne
    /// den gesamten Testlauf zu beenden. `ZIPArchiveInspector` darf nur seine
    /// unmittelbar zuvor geschriebene Staging-Kopie abbilden; fremde Quellen
    /// werden durch `readContents` in den Speicher kopiert.
    func testTruncatingAMappedArchiveCrashesOnlyTheChildProcess() throws {
        if let path = ProcessInfo.processInfo.environment["POORMANS_TEXT_MAPPED_ARCHIVE_CHILD"] {
            try crashAfterTruncatingMappedArchive(at: URL(fileURLWithPath: path))
            XCTFail("Der Zugriff auf die gekürzte Abbildung hätte SIGBUS auslösen müssen.")
            return
        }

        let source = temporaryDirectory.appendingPathComponent("abgebildet.odt")
        try ZIPFixtureBuilder.archive(entries: [
            .init(
                name: "payload",
                content: Data(repeating: 0x41, count: 32 * 1_024),
                isStored: true
            ),
        ]).write(to: source)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "ReviewFixes20260820Tests/testTruncatingAMappedArchiveCrashesOnlyTheChildProcess",
            Bundle(for: Self.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["POORMANS_TEXT_MAPPED_ARCHIVE_CHILD"] = source.path
        process.environment = environment
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(
            process.terminationStatus,
            SIGBUS,
            String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    // MARK: - Keine blockierenden Öffnungsvorgänge mehr

    /// `looksLikeZIP` öffnete blockierend. Eine FIFO ohne Schreiber ließ die
    /// Erkennung deshalb ohne Zeitgrenze stehen; ohne den Fix läuft dieser Test
    /// nicht durch, sondern gar nicht mehr zu Ende.
    func testZIPSignatureCheckRejectsAFIFOInsteadOfWaitingForAWriter() throws {
        let source = temporaryDirectory.appendingPathComponent("rohr.odt")
        guard mkfifo(source.path, 0o600) == 0 else {
            throw XCTSkip("FIFO konnte nicht angelegt werden: \(String(cString: strerror(errno)))")
        }

        XCTAssertFalse(try ZIPArchiveInspector.looksLikeZIP(at: source))
    }

    /// Der Weg, auf dem eine FIFO trotz der `stat`-Prüfung der Eingabe erreichbar
    /// war: Ein Masterdokument verweist auf sie als Abschnittsdatei.
    func testMasterDocumentWithAFIFOSectionFailsInsteadOfHanging() throws {
        let masterURL = temporaryDirectory.appendingPathComponent("Buch.odm")
        try ZIPFixtureBuilder.odmPackage(contentXML: """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
          xmlns:xlink="http://www.w3.org/1999/xlink">
          <office:body><office:text>
            <text:p>Master introduction.</text:p>
            <text:section text:name="Kapitel">
              <text:section-source xlink:href="kapitel.odt" xlink:type="simple"/>
            </text:section>
          </office:text></office:body>
        </office:document-content>
        """).write(to: masterURL)
        let section = temporaryDirectory.appendingPathComponent("kapitel.odt")
        guard mkfifo(section.path, 0o600) == 0 else {
            throw XCTSkip("FIFO konnte nicht angelegt werden: \(String(cString: strerror(errno)))")
        }

        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: masterURL)) { error in
            guard case ConversionError.invalidInput(_, let format, _) = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
            XCTAssertEqual(format, .odm)
        }
    }

    /// Derselbe Weg im RTFD-Paket: Der äußere Ordner ist unauffällig, `TXT.rtf`
    /// darin ist eine FIFO. Auch dieser Test läuft ohne den Fix nicht mehr zu
    /// Ende.
    func testRTFDWithAFIFOInsideFailsInsteadOfHanging() throws {
        let packageURL = temporaryDirectory.appendingPathComponent("Notiz.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let inner = packageURL.appendingPathComponent("TXT.rtf")
        guard mkfifo(inner.path, 0o600) == 0 else {
            throw XCTSkip("FIFO konnte nicht angelegt werden: \(String(cString: strerror(errno)))")
        }

        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: packageURL)) { error in
            guard case ConversionError.invalidInput(_, let format, let reason) = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
            XCTAssertEqual(format, .rtfd)
            XCTAssertTrue(reason.contains("TXT.rtf"), "Unerwarteter Grund: \(reason)")
        }
    }

    // MARK: - RTF hat jetzt ein Größenbudget

    /// Für RTF gab es keine Obergrenze: Farberkennung, Absatz-Rewriter und
    /// Pandoc-Vorbereitung hielten die Datei mehrfach im Speicher. Die Testdatei
    /// ist dünn belegt — sie meldet mehr als 256 MiB, belegt aber fast nichts.
    func testOversizedRTFIsRejectedByTheDetection() throws {
        let source = temporaryDirectory.appendingPathComponent("riesig.rtf")
        try Data(#"{\rtf1\ansi Hallo}"#.utf8).write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(RichTextLimits.maximumSourceSize) + 1)
        try handle.close()

        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: source)) { error in
            guard case ConversionError.invalidInput(_, let format, let reason) = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
            XCTAssertEqual(format, .rtf)
            XCTAssertTrue(reason.contains("size limit"), "Unerwarteter Grund: \(reason)")
        }
    }

    /// Gegenprobe: Eine gewöhnliche RTF-Datei wird weiterhin erkannt.
    func testOrdinaryRTFIsStillDetected() throws {
        let source = temporaryDirectory.appendingPathComponent("klein.rtf")
        try Data(#"{\rtf1\ansi Hallo}"#.utf8).write(to: source)

        XCTAssertEqual(try DocumentConverter().detectFormat(at: source), .rtf)
    }

    // MARK: - Unicode-Path-Extrafelder werden vollständig gelesen

    /// Ein veraltetes erstes `0x7075`-Feld beendete die Suche. Ein zweites,
    /// gültiges Feld — hier mit einem Traversal-Namen — blieb dahinter
    /// unbemerkt.
    func testArchiveRejectsASecondUnicodePathFieldBehindAnOutdatedOne() throws {
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

    // MARK: - Überschriften aus Metadaten bleiben Text

    func testMasterHeadingValueStaysOnOneLineAndKeepsMarkupLiteral() {
        let adapter = OpenDocumentMasterAdapter()

        XCTAssertEqual(adapter.headingText("Kapitel\n# Untergeschoben"), "Kapitel \\# Untergeschoben")
        XCTAssertEqual(adapter.headingText("*fett*"), "\\*fett\\*")
        XCTAssertEqual(adapter.headingText("a\tb   c"), "a b c")
        XCTAssertEqual(adapter.headingText("Bericht 2026"), "Bericht 2026")
    }

    // MARK: - Die Release-Anleitung nennt keine feste Version mehr

    func testReleaseGuideDerivesTheVersionInsteadOfNamingIt() throws {
        let guideURL = projectRoot.appendingPathComponent("docs/GITHUB-RELEASE.md")
        let guide = try String(contentsOf: guideURL, encoding: .utf8)

        XCTAssertTrue(guide.contains("Sources/PoorMansTextCore/ProductInfo.swift"))
        XCTAssertTrue(guide.contains("$VERSION"))
        let literalVersions = guide.matches(of: /[0-9]+\.[0-9]+\.[0-9]+/).map { String($0.output) }
        XCTAssertEqual(literalVersions, [], "Die Anleitung nennt noch feste Versionen")
    }

    // MARK: - Hilfsmittel

    private var worksheetXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>12</v></c></row>
          </sheetData>
        </worksheet>
        """
    }

    private func crashAfterTruncatingMappedArchive(at source: URL) throws {
        let descriptor = open(source.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let length = Int(info.st_size)
        // Der zusätzliche Page-Rand erzwingt nach der Kürzung einen neuen
        // Dateisystemzugriff. Ein exakt bis zum alten Ende reichendes Mapping
        // darf auf aktuellem APFS noch aus dem Page-Cache antworten.
        let mappedLength = length + Int(getpagesize())
        guard let mapped = mmap(nil, mappedLength, PROT_READ, MAP_PRIVATE, descriptor, 0),
              mapped != MAP_FAILED else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(descriptor)
        // Der Austausch kommt von einem zweiten Prozess. Genau das entspricht
        // dem Cloud-Abgleich, der eine vom Import gerade gelesene Quelldatei
        // ersetzt; ein Kürzen durch denselben Prozess darf nicht als Test-Proxy
        // dafür dienen.
        let truncator = Process()
        truncator.executableURL = URL(fileURLWithPath: "/usr/bin/truncate")
        truncator.arguments = ["-s", "\(length / 2)", source.path]
        try truncator.run()
        truncator.waitUntilExit()
        guard truncator.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
        // Bereits im Page-Cache liegende Bytes können den Fehler auf APFS bis
        // zum nächsten echten Seitenabruf verdecken. Das Advising verwirft sie
        // bewusst, damit der Zugriff wieder die nun gekürzte Datei befragen
        // muss.
        guard madvise(mapped, mappedLength, MADV_DONTNEED) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Das Schreiben in stdout verhindert, dass der Optimierer den Zugriff
        // wegfaltet. Genau dieser Bytezugriff trifft nach `truncate` die nicht
        // mehr gültige Seite der Abbildung.
        FileHandle.standardOutput.write(
            Data([mapped.load(fromByteOffset: mappedLength - 1, as: UInt8.self)])
        )
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
