import Foundation
import XCTest
@testable import PoorMansTextCore

/// Die Aufzählung ist die gemeinsame Grundlage für Mehrfachauswahl in CLI und
/// App. Sie muss dieselben Dateien in derselben Reihenfolge liefern, Pakete als
/// ein Dokument behandeln und frühere Ergebnisse nicht erneut umwandeln.
final class InputEnumeratorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextEnumeratorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAFolderYieldsSupportedFilesInFinderOrderAndMirrorsSubfolders() throws {
        try touch("Kapitel 10.docx")
        try touch("Kapitel 2.docx")
        try touch("Notizen.txt")
        try touch("Anhang/Tabelle.XLSX")
        try touch("Anhang/Tief/Scan.pdf")

        let inputs = try InputEnumerator().enumerate([root])

        XCTAssertEqual(
            inputs.map { $0.url.lastPathComponent },
            ["Tabelle.XLSX", "Scan.pdf", "Kapitel 2.docx", "Kapitel 10.docx"]
        )
        XCTAssertEqual(inputs[0].relativeDirectory, ["Anhang"])
        XCTAssertEqual(inputs[1].relativeDirectory, ["Anhang", "Tief"])
        XCTAssertEqual(inputs[2].relativeDirectory, [])
    }

    func testAPackageCountsAsOneDocumentAndIsNotEntered() throws {
        let package = try FixtureFactory.createMinimalRTFD(in: root)
        try Data("png".utf8).write(to: package.appendingPathComponent("inside.png"))

        let fromFolder = try InputEnumerator().enumerate([root])
        XCTAssertEqual(fromFolder.map(\.url), [package])

        // Direkt benannt ist das Paket ebenfalls genau eine Eingabe.
        let direct = try InputEnumerator().enumerate([package])
        XCTAssertEqual(direct, [EnumeratedInput(url: package)])
        XCTAssertFalse(InputEnumerator().isSearchableDirectory(package))
        XCTAssertTrue(InputEnumerator().isSearchableDirectory(root))
    }

    func testEarlierResultsHiddenEntriesAndSymbolicLinksAreSkipped() throws {
        try touch("Bericht.docx")
        try touch("Bericht-markdown/images/image01.png")
        try touch(".versteckt.pdf")
        try touch(".Ordner/Scan.pdf")
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("PoorMansTextEnumeratorOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data().write(to: outside.appendingPathComponent("Fremd.pdf"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Link"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Schleife"),
            withDestinationURL: root
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Verweis.pdf"),
            withDestinationURL: outside.appendingPathComponent("Fremd.pdf")
        )

        let inputs = try InputEnumerator().enumerate([root])

        XCTAssertEqual(inputs.map { $0.url.lastPathComponent }, ["Bericht.docx"])
    }

    func testADirectlyNamedFileIsNotFilteredByExtension() throws {
        let odd = try touch("Unbekannt.data")

        // Die inhaltsbasierte Erkennung soll später den ehrlichen Fehler
        // liefern; die Aufzählung darf ihn nicht vorwegnehmen.
        XCTAssertEqual(try InputEnumerator().enumerate([odd]), [EnumeratedInput(url: odd)])
    }

    func testDuplicatesAreKeptOnceAndArgumentOrderWins() throws {
        let b = try touch("b.pdf")
        let a = try touch("a.pdf")

        let inputs = try InputEnumerator().enumerate([b, root, a])

        XCTAssertEqual(inputs.map(\.url), [b, a])
        // Aus dem Ordner stammend hätte `a.pdf` einen leeren Relativpfad ohnehin;
        // entscheidend ist, dass der Ordner `b.pdf` nicht ein zweites Mal liefert.
        XCTAssertEqual(inputs.count, 2)
    }

    func testMissingPathsAndEmptyFoldersFail() throws {
        let missing = root.appendingPathComponent("fehlt.docx")
        XCTAssertThrowsError(try InputEnumerator().enumerate([missing])) { error in
            XCTAssertEqual(error as? InputEnumerationError, .inputDoesNotExist(missing))
        }

        try touch("Nur Text.txt")
        XCTAssertThrowsError(try InputEnumerator().enumerate([root])) { error in
            XCTAssertEqual(error as? InputEnumerationError, .noSupportedDocuments(root))
        }
    }

    @discardableResult
    private func touch(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
        return url
    }
}
