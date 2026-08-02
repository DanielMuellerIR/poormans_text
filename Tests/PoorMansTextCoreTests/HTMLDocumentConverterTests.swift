import Foundation
import XCTest
@testable import PoorMansTextCore

/// Die gemeinsame Schlussstrecke aller Adapter: Sie erzeugt eine HTML-
/// Zwischendatei im Staging-Verzeichnis und lässt Pandoc daraus Markdown machen.
/// Beide Tests sichern, dass nichts davon in den veröffentlichten Ausgabeordner
/// gelangt und dass ein Fehler danach die richtige Fehlerklasse bekommt.
final class HTMLDocumentConverterTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var workDirectory: URL!
    private var stagedOutputDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextHTMLConverterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        workDirectory = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        stagedOutputDirectory = temporaryDirectory.appendingPathComponent(
            "result",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stagedOutputDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testTheIntermediateHTMLDoesNotSurviveASuccessfulConversion() throws {
        let pandoc = try requirePandoc()

        let conversion = try HTMLDocumentConverter.convert(
            html: "<p>Text</p>",
            inputURL: temporaryDirectory.appendingPathComponent("Source.docx"),
            format: .docx,
            resourceDirectory: workDirectory,
            stagedOutputDirectory: stagedOutputDirectory,
            pandocExecutable: pandoc
        )

        XCTAssertEqual(conversion.markdownRelativePath, "Source.md")
        // `DocumentConverter` verschiebt das ganze Staging-Verzeichnis ans Ziel,
        // nicht nur die gemeldeten Dateien.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: stagedOutputDirectory.path
        )
        XCTAssertFalse(leftovers.contains(".conversion.html"), "\(leftovers)")
    }

    func testAFailedRemovalOfTheIntermediateHTMLIsReported() throws {
        let pandoc = try requirePandoc()

        XCTAssertThrowsError(
            try HTMLDocumentConverter.convert(
                html: "<p>Text</p>",
                inputURL: temporaryDirectory.appendingPathComponent("Source.docx"),
                format: .docx,
                resourceDirectory: workDirectory,
                stagedOutputDirectory: stagedOutputDirectory,
                pandocExecutable: pandoc,
                fileManager: RemovalRefusingFileManager()
            )
        ) { error in
            guard case ConversionError.fileSystemFailure = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMissingPandocOutputIsAFileSystemFailureNotAnInvalidInput() throws {
        // Ein Pandoc-Ersatz, der 0 liefert, aber nichts schreibt. Vorher machte
        // die Schlussstrecke daraus `invalidInput`, also Exit 65 statt 74 — ein
        // gueltiges Quelldokument bekam die Schuld an einem fehlenden Artefakt.
        let silentPandoc = temporaryDirectory.appendingPathComponent("silent-pandoc")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: silentPandoc)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: silentPandoc.path
        )

        XCTAssertThrowsError(
            try HTMLDocumentConverter.convert(
                html: "<p>Text</p>",
                inputURL: temporaryDirectory.appendingPathComponent("Source.docx"),
                format: .docx,
                resourceDirectory: workDirectory,
                stagedOutputDirectory: stagedOutputDirectory,
                pandocExecutable: silentPandoc
            )
        ) { error in
            guard case ConversionError.fileSystemFailure = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func requirePandoc() throws -> URL {
        do {
            return try PandocTool.resolve(nil)
        } catch {
            throw XCTSkip("Pandoc is required for this test.")
        }
    }
}

/// Simuliert einen Löschfehler, ohne das Dateisystem zu manipulieren.
private final class RemovalRefusingFileManager: FileManager {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
