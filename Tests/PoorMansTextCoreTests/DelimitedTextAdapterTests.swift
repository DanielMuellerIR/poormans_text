import Foundation
import XCTest
@testable import PoorMansTextCore

/// CSV und TSV laufen als Ein-Blatt-Mappe durch den Tabellen-Renderer. Die
/// Endung entscheidet über die Erkennung, der Inhalt über Trennzeichen,
/// Kodierung und Gültigkeit.
final class DelimitedTextAdapterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCSVTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSemicolonCSVWithQuotesAndEmbeddedNewlinesBecomesATable() throws {
        let csv = "Name;Preis;Notiz\r\n\"Müller, Anna\";12,50;\"Zeile 1\nZeile 2\"\r\nSchmidt;7;\"Er sagte \"\"Hallo\"\"\"\r\n"
        let sourceURL = root.appendingPathComponent("Preise.csv")
        try Data(csv.utf8).write(to: sourceURL)

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))

        XCTAssertEqual(result.format, .csv)
        XCTAssertTrue(result.diagnostics.isEmpty, result.warnings.joined())
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Sheet: Preise"), markdown)
        XCTAssertTrue(markdown.contains("| Name | Preis | Notiz |"), markdown)
        XCTAssertTrue(markdown.contains("| Müller, Anna | 12,50 | Zeile 1<br>Zeile 2 |"), markdown)
        XCTAssertTrue(markdown.contains("Er sagte \"Hallo\""), markdown)
    }

    func testTSVUsesTabsEvenWhenCellsContainCommas() throws {
        let tsv = "A\tB\n1,5\t2,5\n"
        let sourceURL = root.appendingPathComponent("Werte.tsv")
        try Data(tsv.utf8).write(to: sourceURL)

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))

        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("| 1,5 | 2,5 |"), markdown)
    }

    func testWindows1252IsReadWithAWarningAndBOMsAreHonored() throws {
        let latin = root.appendingPathComponent("Latin.csv")
        try Data("Ort,Größe\nKöln,groß\n".data(using: .windowsCP1252)!).write(to: latin)
        let latinResult = try DocumentConverter().convert(ConversionRequest(inputURL: latin))
        XCTAssertTrue(latinResult.diagnostics.contains(.delimitedTextEncodingAssumed))
        XCTAssertTrue(try String(contentsOf: latinResult.markdownFile, encoding: .utf8).contains("| Köln | groß |"))
        XCTAssertTrue(try DocumentConverter().inspect(latin).expectedWarnings.contains(.delimitedTextEncodingAssumed))

        let utf16 = root.appendingPathComponent("Utf16.csv")
        var bytes = Data([0xFF, 0xFE])
        bytes.append("x,y\nä,ö\n".data(using: .utf16LittleEndian)!)
        try bytes.write(to: utf16)
        let utf16Result = try DocumentConverter().convert(ConversionRequest(inputURL: utf16))
        XCTAssertTrue(utf16Result.diagnostics.isEmpty)
        XCTAssertTrue(try String(contentsOf: utf16Result.markdownFile, encoding: .utf8).contains("| ä | ö |"))

        let bom = root.appendingPathComponent("Bom.csv")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("k,v\n1,2\n".utf8)).write(to: bom)
        let bomResult = try DocumentConverter().convert(ConversionRequest(inputURL: bom))
        XCTAssertTrue(try String(contentsOf: bomResult.markdownFile, encoding: .utf8).contains("| k | v |"))
    }

    func testBinaryContentAndForeignExtensionsAreRejected() throws {
        let binary = root.appendingPathComponent("Bild.csv")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: binary)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: binary))) { error in
            guard case ConversionError.invalidInput(_, let format, let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(format, .csv)
            XCTAssertTrue(reason.contains("binary"), reason)
        }

        // Ohne die Endung ist reiner Text keine Tabelle; er bleibt unbekannt.
        let text = root.appendingPathComponent("Notiz.txt")
        try Data("a,b\n1,2\n".utf8).write(to: text)
        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: text))) { error in
            guard case ConversionError.unsupportedInput = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDelimiterSniffingPrefersTheConsistentSeparator() {
        XCTAssertEqual(DelimitedTextParser.sniffDelimiter(in: "a;b;c\n1;2;3\n"), ";")
        XCTAssertEqual(DelimitedTextParser.sniffDelimiter(in: "a,b\n1,2\n"), ",")
        XCTAssertEqual(DelimitedTextParser.sniffDelimiter(in: "a|b\n1|2\n"), "|")
        // Kommas im Text, Semikolons als Struktur: das gleichmäßige Zeichen gewinnt.
        XCTAssertEqual(DelimitedTextParser.sniffDelimiter(in: "Name;Ort\nMüller, A.;Köln\nB;C, D, E\n"), ";")
        XCTAssertEqual(DelimitedTextParser.sniffDelimiter(in: "nur text\nohne trenner\n"), ",")
    }

    func testTheLastLineWithoutANewlineCountsAndAnEmptyFileHasNoRows() throws {
        XCTAssertEqual(try DelimitedTextParser.parse("a,b\n1,2", delimiter: ",").count, 2)
        XCTAssertEqual(try DelimitedTextParser.parse("", delimiter: ",").count, 0)
        XCTAssertEqual(try DelimitedTextParser.parse("x\r\n", delimiter: ",").count, 1)
    }
}
