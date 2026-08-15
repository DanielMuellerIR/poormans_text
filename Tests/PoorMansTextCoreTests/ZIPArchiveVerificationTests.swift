import Foundation
import XCTest
@testable import PoorMansTextCore

/// Prüft die Absicherung der ZIP-Strecke gegen Pakete, die über ihre Einträge
/// lügen, und die unveränderliche Arbeitskopie, die Pandoc bekommt.
final class ZIPArchiveVerificationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var workDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextZIPVerificationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        workDirectory = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testStagedCopyStaysUnchangedWhenTheSourceIsReplacedAfterwards() throws {
        let archive = try ZIPFixtureBuilder.wordProcessingPackage()
        let sourceURL = temporaryDirectory.appendingPathComponent("Source.docx")
        try archive.write(to: sourceURL)

        let stagedURL = try ZIPArchiveInspector.stageVerifiedPackage(
            from: sourceURL,
            into: workDirectory,
            named: "verified-source.docx"
        )
        XCTAssertEqual(try Data(contentsOf: stagedURL), archive)
        XCTAssertNotEqual(stagedURL.standardizedFileURL, sourceURL.standardizedFileURL)

        // Genau dieser Austausch ist die Time-of-check-to-time-of-use-Lücke: Der
        // Originalpfad ändert sich, die geprüfte Arbeitskopie darf das nicht.
        try Data("not a ZIP any more".utf8).write(to: sourceURL)

        XCTAssertEqual(try Data(contentsOf: stagedURL), archive)
        let inspection = try ZIPArchiveInspector.inspectWordProcessingPackage(at: stagedURL)
        XCTAssertEqual(inspection?.format, .docx)
    }

    func testRejectsAMediaEntryThatExpandsBeyondItsDeclaredSize() throws {
        // Der Medieneintrag entpackt sich auf 1 MiB, deklariert aber 32 Byte.
        // Ohne echte Größenprüfung zählt das Entpackbudget nur die 32 Byte.
        let archive = try ZIPFixtureBuilder.wordProcessingPackage(
            mediaContent: Data(repeating: 0x41, count: 1_048_576),
            declaredMediaSize: 32
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("Bomb.docx")
        try archive.write(to: sourceURL)

        XCTAssertThrowsError(
            try ZIPArchiveInspector.stageVerifiedPackage(
                from: sourceURL,
                into: workDirectory,
                named: "verified-source.docx"
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("expands beyond"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testRejectsAMediaEntryWithAWrongChecksum() throws {
        let archive = try ZIPFixtureBuilder.wordProcessingPackage(
            mediaContent: Data(repeating: 0x42, count: 4096),
            declaredMediaChecksum: 0xDEAD_BEEF
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("Tampered.docx")
        try archive.write(to: sourceURL)

        XCTAssertThrowsError(
            try ZIPArchiveInspector.stageVerifiedPackage(
                from: sourceURL,
                into: workDirectory,
                named: "verified-source.docx"
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("checksum"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testConversionRejectsAPackageWhoseMediaLiesAboutItsSize() throws {
        let archive = try ZIPFixtureBuilder.wordProcessingPackage(
            mediaContent: Data(repeating: 0x43, count: 1_048_576),
            declaredMediaSize: 32
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("Bomb.docx")
        try archive.write(to: sourceURL)
        let outputURL = temporaryDirectory.appendingPathComponent("Bomb-result", isDirectory: true)

        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(inputURL: sourceURL, destination: .directory(outputURL))
            )
        ) { error in
            guard case ConversionError.invalidInput(_, let format, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(format, .docx)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), archive)
    }

    func testRejectsAPackageWithTwoIdenticallyNamedEntries() throws {
        let archive = try ZIPFixtureBuilder.archive(
            entries: duplicateMediaEntries(secondMediaName: "word/media/image1.bin")
        )
        try assertRejectsAsDuplicate(archive, fileName: "Duplicate.docx")
    }

    func testRejectsAPackageWhoseEntriesDifferOnlyInCase() throws {
        // Auf dem case-insensitiven APFS landen beide Einträge beim Entpacken auf
        // derselben Datei, der zweite überschriebe den ersten unbemerkt.
        let archive = try ZIPFixtureBuilder.archive(
            entries: duplicateMediaEntries(secondMediaName: "word/media/IMAGE1.bin")
        )
        try assertRejectsAsDuplicate(archive, fileName: "CaseDuplicate.docx")
    }

    /// Ein DOCX-ähnliches Paket, dessen Medieneintrag ein zweites Mal unter
    /// `secondMediaName` auftaucht.
    private func duplicateMediaEntries(secondMediaName: String) -> [ZIPFixtureBuilder.Entry] {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Override PartName="/word/document.xml" ContentType="\(ZIPFixtureBuilder.docxMainContentType)"/>
        </Types>
        """
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>Fixture text</w:t></w:r></w:p></w:body>
        </w:document>
        """
        return [
            ZIPFixtureBuilder.Entry(
                name: "[Content_Types].xml",
                content: Data(contentTypes.utf8)
            ),
            ZIPFixtureBuilder.Entry(name: "word/document.xml", content: Data(documentXML.utf8)),
            ZIPFixtureBuilder.Entry(
                name: "word/media/image1.bin",
                content: Data(repeating: 0x2E, count: 4096)
            ),
            ZIPFixtureBuilder.Entry(
                name: secondMediaName,
                content: Data(repeating: 0x2F, count: 4096)
            ),
        ]
    }

    private func assertRejectsAsDuplicate(
        _ archive: Data,
        fileName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(fileName)
        try archive.write(to: sourceURL)

        XCTAssertThrowsError(
            try ZIPArchiveInspector.stageVerifiedPackage(
                from: sourceURL,
                into: workDirectory,
                named: "verified-source.docx"
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("duplicate entry"),
                "Unexpected error: \(error.localizedDescription)",
                file: file,
                line: line
            )
        }
    }

    func testAcceptsTheVersionedRealPackagesOfBothProducers() throws {
        for name in ["pandoc.docx", "libreoffice.docx", "pandoc.odt", "libreoffice.odt"] {
            let stagedURL = try ZIPArchiveInspector.stageVerifiedPackage(
                from: fixture(name),
                into: workDirectory,
                named: "verified-\(name)"
            )
            XCTAssertEqual(
                try Data(contentsOf: stagedURL),
                try Data(contentsOf: fixture(name)),
                "Staged copy of \(name) differs from the source"
            )
        }
    }

    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/WordProcessing")
            .appendingPathComponent(name)
    }
}
