import Foundation
import XCTest
@testable import PoorMansTextCore

final class PandocToolTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextPandocToolTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testADirectoryIsNotAcceptedAsPandoc() throws {
        // Unter POSIX bedeutet das Ausführrecht bei einem Verzeichnis nur
        // „durchsuchbar". `isExecutableFile` sagt deshalb auch hier ja.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: temporaryDirectory.path))

        XCTAssertThrowsError(try PandocTool.resolve(temporaryDirectory)) { error in
            guard case ConversionError.pandocNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        // Sonst meldete `--formats` das Format als verfügbar und erst der
        // Prozessstart scheiterte als Softwarefehler.
        XCTAssertFalse(
            ExternalToolResolver(pandocExecutable: temporaryDirectory).isAvailable(.pandoc)
        )
    }

    func testASymbolicLinkToTheRealPandocStaysAcceptable() throws {
        guard let pandoc = try? PandocTool.resolve(nil) else {
            throw XCTSkip("Pandoc is required for this test.")
        }
        // Homebrew verlinkt `pandoc` genau so; die Prüfung darf Symlinks auf
        // reguläre Dateien nicht mit Verzeichnissen in einen Topf werfen.
        let linkURL = temporaryDirectory.appendingPathComponent("pandoc")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: pandoc)

        XCTAssertEqual(try PandocTool.resolve(linkURL).path, linkURL.path)
        XCTAssertTrue(ExternalToolResolver(pandocExecutable: linkURL).isAvailable(.pandoc))
    }
}
