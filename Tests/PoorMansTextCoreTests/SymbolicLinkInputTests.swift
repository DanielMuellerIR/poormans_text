import Foundation
import XCTest
@testable import PoorMansTextCore

/// Ein Symlink auf ein Dokument ist ein übliches Ordnungsmittel — er muss
/// genauso konvertierbar sein wie das Original.
///
/// Vor der Behebung gelang das nur bei RTF. DOCX, ODT, ODS und XLSX scheiterten
/// an einer `isRegularFile`-Prüfung, die den Verweis selbst beschrieb statt sein
/// Ziel; DOC und die ZIP-Pakete zusätzlich am `O_NOFOLLOW` beim Öffnen der
/// Quelle; XLS meldete irreführend eine fehlende ZIP-Signatur; und RTFD scheiterte
/// daran, dass `textutil` einen Symlink auf ein Paket nicht öffnet.
final class SymbolicLinkInputTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextSymlinkTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - Jeder Weg akzeptiert einen Verweis

    func testZIPPackagesConvertThroughASymbolicLink() throws {
        try assertSymbolicLinkMatchesOriginal(
            of: fixture("WordProcessing/pandoc.docx"),
            named: "verweis.docx",
            expecting: .docx
        )
    }

    func testLegacyDOCConvertsThroughASymbolicLink() throws {
        try assertSymbolicLinkMatchesOriginal(
            of: fixture("WordProcessing/textutil.doc"),
            named: "verweis.doc",
            expecting: .doc
        )
    }

    func testODSConvertsThroughASymbolicLink() throws {
        try assertSymbolicLinkMatchesOriginal(
            of: fixture("Spreadsheets/multisheet.ods"),
            named: "verweis.ods",
            expecting: .ods
        )
    }

    func testLegacyXLSConvertsThroughASymbolicLink() throws {
        try assertSymbolicLinkMatchesOriginal(
            of: fixture("Spreadsheets/not-word.xls"),
            named: "verweis.xls",
            expecting: .xls
        )
    }

    func testRTFDPackageConvertsThroughASymbolicLink() throws {
        let original = try FixtureFactory.createMinimalRTFD(
            in: temporaryDirectory,
            name: "Original.rtfd"
        )
        try assertSymbolicLinkMatchesOriginal(
            of: original,
            named: "verweis.rtfd",
            expecting: .rtfd
        )
    }

    // MARK: - Der Verweis verschiebt das Ergebnis nicht

    func testOutputStaysNextToTheLinkNotNextToItsTarget() throws {
        // Der Nutzer hat den Verweis ausgewählt, nicht das Original. Der
        // Nachbarordner gehört deshalb neben den Verweis, sonst taucht das
        // Ergebnis an einer Stelle auf, die er gar nicht im Blick hatte.
        let targetDirectory = temporaryDirectory.appendingPathComponent("ziel", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let target = targetDirectory.appendingPathComponent("Original.docx")
        try Data(contentsOf: fixture("WordProcessing/pandoc.docx")).write(to: target)

        let linkURL = temporaryDirectory.appendingPathComponent("Verweis.docx")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: linkURL))

        XCTAssertEqual(
            result.outputDirectory.standardizedFileURL,
            temporaryDirectory.appendingPathComponent("Verweis-markdown", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: targetDirectory.appendingPathComponent("Original-markdown").path
            ),
            "Das Ergebnis darf nicht beim Ziel des Verweises landen."
        )
    }

    // MARK: - Die Härtung bleibt erhalten

    func testADirectoryBehindALinkIsStillRejected() throws {
        // Die Symlink-Auflösung darf die Prüfung nicht aushebeln: Hinter dem
        // Verweis liegt ein Verzeichnis, kein Paket.
        let directory = temporaryDirectory.appendingPathComponent("kein-paket", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let linkURL = temporaryDirectory.appendingPathComponent("verweis.xlsx")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: directory)

        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: linkURL))
    }

    func testTheXLSPathStagesThroughTheVerifiedCopyAndLeavesTheSourceUntouched() throws {
        // Der XLS-Zweig kopierte früher mit `copyItem`, nachdem er den Pfad
        // geprüft hatte. Jetzt läuft er über dieselbe Staging-Schicht wie DOC
        // und die ZIP-Pakete; die Quelle bleibt dabei unverändert.
        let source = temporaryDirectory.appendingPathComponent("Mappe.xls")
        try Data(contentsOf: fixture("Spreadsheets/not-word.xls")).write(to: source)
        let before = try Data(contentsOf: source)

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source))

        XCTAssertEqual(result.format, .xls)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testTheXLSPathRejectsASourceBeyondTheStagingBudget() throws {
        // Belegt, dass die Größengrenze nach der Umstellung noch greift — und
        // zwar in der Staging-Schicht selbst, vor dem ersten geschriebenen Byte.
        let source = temporaryDirectory.appendingPathComponent("zu-gross.bin")
        try Data(repeating: 0x42, count: 8192).write(to: source)
        let destination = temporaryDirectory.appendingPathComponent("staged.xls")

        XCTAssertThrowsError(
            try VerifiedFileStaging.stage(
                from: source,
                to: destination,
                maximumBytes: 4096,
                describedAs: "the XLS source"
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("XLS source"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testStagingStillRefusesToWriteThroughASymbolicLinkDestination() throws {
        // Nur die QUELLE darf einem Verweis folgen. Ein untergeschobener
        // Symlink als ZIEL muss weiterhin abgelehnt werden, sonst schriebe das
        // Staging in eine fremde Datei.
        let source = temporaryDirectory.appendingPathComponent("quelle.bin")
        try Data("Inhalt".utf8).write(to: source)
        let outside = temporaryDirectory.appendingPathComponent("fremd.txt")
        try Data("unberührt".utf8).write(to: outside)
        let destination = temporaryDirectory.appendingPathComponent("staged.bin")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)

        XCTAssertThrowsError(
            try VerifiedFileStaging.stage(
                from: source,
                to: destination,
                maximumBytes: 1_048_576,
                describedAs: "the source"
            )
        )
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "unberührt")
    }

    // MARK: - Hilfen

    private func fixture(_ relativePath: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(relativePath)
    }

    /// Konvertiert Original und Verweis und vergleicht beide Ergebnisse.
    ///
    /// Der Dateiname darf abweichen — er folgt der Nutzereingabe —, der
    /// Markdown-Rumpf und die gemeldeten Warnungen dürfen es nicht.
    private func assertSymbolicLinkMatchesOriginal(
        of originalURL: URL,
        named linkName: String,
        expecting format: InputFormat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let linkURL = temporaryDirectory.appendingPathComponent(linkName)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: originalURL)
        let converter = DocumentConverter()

        XCTAssertEqual(try converter.detectFormat(at: linkURL), format, file: file, line: line)

        let viaOriginal = try converter.convert(
            ConversionRequest(inputURL: originalURL, destination: .temporary)
        )
        let viaLink = try converter.convert(
            ConversionRequest(inputURL: linkURL, destination: .temporary)
        )
        defer {
            try? FileManager.default.removeItem(at: viaOriginal.outputDirectory)
            try? FileManager.default.removeItem(at: viaLink.outputDirectory)
        }

        XCTAssertEqual(viaLink.format, format, file: file, line: line)
        XCTAssertEqual(
            viaLink.diagnostics.map(\.code),
            viaOriginal.diagnostics.map(\.code),
            file: file,
            line: line
        )
        // Die erste Zeile trägt bei Tabellen den Dokumentnamen und weicht damit
        // zulässig ab; alles danach muss Zeichen für Zeichen übereinstimmen.
        XCTAssertEqual(
            try bodyWithoutTitle(of: viaLink.markdownFile),
            try bodyWithoutTitle(of: viaOriginal.markdownFile),
            file: file,
            line: line
        )
        XCTAssertEqual(
            viaLink.assets.map(\.lastPathComponent),
            viaOriginal.assets.map(\.lastPathComponent),
            file: file,
            line: line
        )
    }

    private func bodyWithoutTitle(of markdownURL: URL) throws -> String {
        let text = try String(contentsOf: markdownURL, encoding: .utf8)
        guard let firstBreak = text.firstIndex(of: "\n") else { return "" }
        return String(text[text.index(after: firstBreak)...])
    }
}
