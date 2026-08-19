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

    func testRejectsAPackageWhoseEntriesCollideAfterUnicodeCaseFolding() throws {
        // Case-insensitives APFS behandelt Sigma und Schluss-Sigma als denselben
        // Dateinamen, obwohl String.lowercased() zwei verschiedene Werte liefert.
        let archive = try ZIPFixtureBuilder.archive(
            entries: duplicateMediaEntries(secondMediaName: "word/media/ς.png")
                .map { entry in
                    guard entry.name == "word/media/image1.bin" else { return entry }
                    return ZIPFixtureBuilder.Entry(
                        name: "word/media/σ.png",
                        content: entry.content
                    )
                }
        )
        try assertRejectsAsDuplicate(archive, fileName: "UnicodeCaseDuplicate.docx")
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

    // MARK: - Symlink-Gate gilt für jedes Host-System

    func testSymbolicLinkEntriesAreRejectedWhicheverHostSystemDeclaresThem() throws {
        // Die Ablehnung hing früher an `hostSystem == 3` (Unix). Derselbe
        // Eintrag unter „OS X (Darwin)" (19) oder MS-DOS (0) kam damit durch
        // das Gate — und gerade 0 schreiben Word, LibreOffice und Pandoc.
        for hostSystem in [UInt8(0), UInt8(3), UInt8(19)] {
            let archive = try ZIPFixtureBuilder.wordProcessingPackage(
                mediaContent: Data("/etc/passwd".utf8),
                mediaHostSystem: hostSystem,
                mediaExternalAttributes: UInt32(0o120_777) << 16
            )
            let sourceURL = temporaryDirectory.appendingPathComponent(
                "symlink-host\(hostSystem).docx"
            )
            try archive.write(to: sourceURL)

            XCTAssertThrowsError(
                try ZIPArchiveInspector.stageVerifiedPackage(
                    from: sourceURL,
                    into: workDirectory,
                    named: "verified-host\(hostSystem).docx"
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("symbolic links are not allowed"),
                    "Host \(hostSystem) unerwartet: \(error.localizedDescription)"
                )
            }
        }
    }

    func testARegularEntryIsStillAcceptedUnderAUnixHostSystem() throws {
        // Gegenprobe: Die breitere Prüfung darf ein gewöhnliches Paket nicht
        // ablehnen, nur weil sein Erzeuger ein Unix-artiges Host-System und
        // einen gewöhnlichen Dateimodus einträgt.
        let archive = try ZIPFixtureBuilder.wordProcessingPackage(
            mediaHostSystem: 3,
            mediaExternalAttributes: UInt32(0o100_644) << 16
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("regular-unix.docx")
        try archive.write(to: sourceURL)

        let stagedURL = try ZIPArchiveInspector.stageVerifiedPackage(
            from: sourceURL,
            into: workDirectory,
            named: "verified-source.docx"
        )
        XCTAssertEqual(try Data(contentsOf: stagedURL), archive)
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

/// Review-Fund 2026-08-17: Die Namensdekodierung ignorierte das
/// General-Purpose-Bit 11 und las jeden Namen erst als UTF-8, ersatzweise als
/// ISO-8859-1. Ein regelkonformer CP437-Name ohne Bit 11 wurde dadurch falsch
/// gelesen — und das Kollisions-Gate sah zwei Namen, die ein Entpacker auf
/// einem case-insensitiven Dateisystem als denselben Pfad behandelt.
final class ZIPEntryNameEncodingTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var workDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextZIPNameTests-\(UUID().uuidString)",
            isDirectory: true
        )
        workDirectory = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testDetectsCP437NamesThatCollideAfterCaseFolding() throws {
        // Rohbyte 0x80 ist in CP437 `Ç`, 0x87 ist `ç` — auf einem
        // case-insensitiven Dateisystem derselbe Pfad. Als ISO-8859-1 gelesen
        // wären es die verschiedenen Steuerzeichen U+0080 und U+0087, und die
        // Kollision bliebe unbemerkt.
        let archive = try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "[Content_Types].xml",
                content: Data(Self.contentTypes.utf8)
            ),
            ZIPFixtureBuilder.Entry(
                name: "word/document.xml",
                content: Data(Self.documentXML.utf8)
            ),
            Self.cp437MediaEntry(highByte: 0x80),
            Self.cp437MediaEntry(highByte: 0x87),
        ])

        try assertRejected(archive, named: "CP437Duplicate.docx", containing: "duplicate entry")
    }

    func testRejectsANameThatClaimsUTF8ButIsNot() throws {
        // Bit 11 gesetzt heißt: der Name IST UTF-8. Ein stiller Rückfall auf
        // eine andere Kodierung würde einen anderen Pfad ergeben, als ein
        // regelkonformer Entpacker anlegt.
        var invalidName = Data("word/media/".utf8)
        invalidName.append(contentsOf: [0xFF, 0xFE])     // kein gültiges UTF-8
        let archive = try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "[Content_Types].xml",
                content: Data(Self.contentTypes.utf8)
            ),
            ZIPFixtureBuilder.Entry(
                name: "word/document.xml",
                content: Data(Self.documentXML.utf8)
            ),
            ZIPFixtureBuilder.Entry(
                name: "word/media/broken",
                content: Data("x".utf8),
                rawNameBytes: invalidName,
                explicitFlags: 0x0800
            ),
        ])

        try assertRejected(archive, named: "BrokenUTF8.docx", containing: "UTF-8")
    }

    // MARK: - Unicode-Path-Extrafeld (Review-Fund 2026-08-19)

    /// Der Kern des Fundes: Der Eintrag trägt echten Inhalt unter dem Rohnamen
    /// `word/media/image1.bin`, tritt über sein Unicode-Feld aber als Verzeichnis
    /// `benign/` auf. `verifyEntryContents` überspringt Verzeichnisse — Größe und
    /// CRC dieses Eintrags wären nie geprüft worden, während ein Verbraucher ohne
    /// Unterstützung für das Feld die ungeprüfte Nutzlast unter dem Rohnamen
    /// bekommt.
    func testRejectsAnEntryThatIsOnlyADirectoryThroughItsUnicodeName() throws {
        let archive = try ZIPFixtureBuilder.archive(entries: [
            Self.contentTypesEntry,
            Self.documentEntry,
            ZIPFixtureBuilder.Entry(
                name: "word/media/image1.bin",
                content: Data(repeating: 0x2E, count: 4096),
                declaredUncompressedSize: 8,
                centralUnicodePathName: "benign/"
            ),
        ])

        try assertRejected(
            archive,
            named: "UnicodeDirectoryAlias.docx",
            containing: "disagree about being a directory"
        )
    }

    /// Die Gegenrichtung: Der Rohname bricht aus dem Paket aus, das Unicode-Feld
    /// nennt einen harmlosen Pfad. Geprüft wurde bisher nur der bevorzugte Name,
    /// entpackt hätte ein Verbraucher ohne das Feld aber den Rohnamen.
    func testRejectsAnUnsafeRawNameBehindAHarmlessUnicodeName() throws {
        let archive = try ZIPFixtureBuilder.archive(entries: [
            Self.contentTypesEntry,
            Self.documentEntry,
            ZIPFixtureBuilder.Entry(
                name: "word/media/image1.bin",
                content: Data(repeating: 0x2E, count: 64),
                rawNameBytes: Data("../escaped.bin".utf8),
                centralUnicodePathName: "word/media/image1.bin"
            ),
        ])

        try assertRejected(archive, named: "UnicodeMask.docx", containing: "unsafe entry path")
    }

    /// Das Extrafeld steht zweimal im Archiv. Wer den Namen aus dem lokalen
    /// Header liest, bekäme sonst einen anderen Pfad als den geprüften.
    func testRejectsALocalHeaderThatDeclaresADifferentUnicodePath() throws {
        let archive = try ZIPFixtureBuilder.archive(entries: [
            Self.contentTypesEntry,
            Self.documentEntry,
            ZIPFixtureBuilder.Entry(
                name: "word/media/image1.bin",
                content: Data(repeating: 0x2E, count: 64),
                centralUnicodePathName: "word/media/zentral.bin",
                localUnicodePathName: "word/media/lokal.bin"
            ),
        ])

        try assertRejected(
            archive,
            named: "UnicodeSplit.docx",
            containing: "declares a different Unicode path"
        )
    }

    /// Zwei Einträge mit demselben Rohnamen und verschiedenen Unicode-Namen: Für
    /// einen Verbraucher ohne das Feld ist das ein doppelter Eintrag, bei dem
    /// einer den anderen still überschreibt.
    func testRejectsTwoEntriesThatShareTheirRawNameBehindDifferentUnicodeNames() throws {
        let rawName = Data("word/media/image1.bin".utf8)
        let archive = try ZIPFixtureBuilder.archive(entries: [
            Self.contentTypesEntry,
            Self.documentEntry,
            ZIPFixtureBuilder.Entry(
                name: "word/media/first.bin",
                content: Data(repeating: 0x2E, count: 64),
                rawNameBytes: rawName,
                centralUnicodePathName: "word/media/first.bin"
            ),
            ZIPFixtureBuilder.Entry(
                name: "word/media/second.bin",
                content: Data(repeating: 0x2F, count: 64),
                rawNameBytes: rawName,
                centralUnicodePathName: "word/media/second.bin"
            ),
        ])

        try assertRejected(archive, named: "UnicodeRawDuplicate.docx", containing: "duplicate entry")
    }

    /// Ein Verzeichniseintrag mit Nutzlast: `verifyEntryContents` überspringt ihn,
    /// deshalb darf er gar keine haben.
    func testRejectsADirectoryEntryThatDeclaresContent() throws {
        let archive = try ZIPFixtureBuilder.archive(entries: [
            Self.contentTypesEntry,
            Self.documentEntry,
            ZIPFixtureBuilder.Entry(
                name: "word/media/",
                content: Data(repeating: 0x2E, count: 4096)
            ),
        ])

        try assertRejected(
            archive,
            named: "DirectoryWithContent.docx",
            containing: "directory entry declares content"
        )
    }

    /// Gegenprobe: Ein regelkonformes Feld wird weiterhin genommen. Der Rohname
    /// steht in CP437 (`0x84` ist dort `ä`), das Feld nennt denselben Pfad als
    /// UTF-8 — Datei bleibt Datei, und das Paket wandelt sich um.
    func testAcceptsAUnicodePathFieldThatMatchesTheRawName() throws {
        var rawName = Data("word/media/b".utf8)
        rawName.append(0x84)
        rawName.append(contentsOf: Data("ume.bin".utf8))
        let archive = try ZIPFixtureBuilder.archive(entries: [
            Self.contentTypesEntry,
            Self.documentEntry,
            ZIPFixtureBuilder.Entry(
                name: "word/media/bäume.bin",
                content: Data(repeating: 0x2E, count: 64),
                rawNameBytes: rawName,
                explicitFlags: 0,                       // kein Bit 11 -> CP437
                centralUnicodePathName: "word/media/bäume.bin"
            ),
        ])
        let sourceURL = temporaryDirectory.appendingPathComponent("UnicodeMatch.docx")
        try archive.write(to: sourceURL)

        let stagedURL = try ZIPArchiveInspector.stageVerifiedPackage(
            from: sourceURL,
            into: workDirectory,
            named: "verified-source.docx"
        )

        XCTAssertEqual(try Data(contentsOf: stagedURL), archive)
    }

    private static let contentTypesEntry = ZIPFixtureBuilder.Entry(
        name: "[Content_Types].xml",
        content: Data(contentTypes.utf8)
    )

    private static let documentEntry = ZIPFixtureBuilder.Entry(
        name: "word/document.xml",
        content: Data(documentXML.utf8)
    )

    /// Ein CP437-Medienname aus `word/media/` plus genau einem hohen Byte.
    private static func cp437MediaEntry(highByte: UInt8) -> ZIPFixtureBuilder.Entry {
        var rawName = Data("word/media/".utf8)
        rawName.append(highByte)
        rawName.append(contentsOf: Data(".bin".utf8))
        return ZIPFixtureBuilder.Entry(
            name: "word/media/cp437-\(highByte).bin",
            content: Data(repeating: 0x2E, count: 64),
            rawNameBytes: rawName,
            explicitFlags: 0                       // kein Bit 11 -> CP437
        )
    }

    private func assertRejected(
        _ archive: Data,
        named fileName: String,
        containing needle: String,
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
                error.localizedDescription.contains(needle),
                "Unexpected error: \(error.localizedDescription)",
                file: file,
                line: line
            )
        }
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Override PartName="/word/document.xml" ContentType="\(ZIPFixtureBuilder.docxMainContentType)"/>
    </Types>
    """

    private static let documentXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:body><w:p><w:r><w:t>Fixture text</w:t></w:r></w:p></w:body>
    </w:document>
    """
}
