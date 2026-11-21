import Foundation
import XCTest
@testable import PoorMansTextCore

final class RichTextConversionRegressionTests: XCTestCase {
    /// Derselbe Weg im RTFD-Paket: Der äußere Ordner ist unauffällig, `TXT.rtf`
    /// darin ist eine FIFO. Auch dieser Test läuft ohne den Fix nicht mehr zu
    /// Ende.
    func testRTFDWithAFIFOInsideFailsInsteadOfHanging() throws {
        let temporaryDirectory = try makeRegressionDirectory()
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

    /// Für RTF gab es keine Obergrenze: Farberkennung, Absatz-Rewriter und
    /// Pandoc-Vorbereitung hielten die Datei mehrfach im Speicher. Die Testdatei
    /// ist dünn belegt — sie meldet mehr als 256 MiB, belegt aber fast nichts.
    func testOversizedRTFIsRejectedByTheDetection() throws {
        let temporaryDirectory = try makeRegressionDirectory()
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
        let temporaryDirectory = try makeRegressionDirectory()
        let source = temporaryDirectory.appendingPathComponent("klein.rtf")
        try Data(#"{\rtf1\ansi Hallo}"#.utf8).write(to: source)

        XCTAssertEqual(try DocumentConverter().detectFormat(at: source), .rtf)
    }

    func testRTFDSnapshotRejectsAnEmbeddedSymbolicLink() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let package = temporaryDirectory.appendingPathComponent("Unsafe.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let outside = temporaryDirectory.appendingPathComponent("outside.rtf")
        try Data(#"{\rtf1\ansi outside}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("TXT.rtf"),
            withDestinationURL: outside
        )

        let detection = try RichTextAdapter().inspectInput(at: package)
        guard case .invalid(.rtfd, _, let reason) = detection else {
            return XCTFail("Unexpected detection: \(detection)")
        }
        XCTAssertTrue(reason.contains("symbolic link"), reason)
    }

    func testRTFDSnapshotUsesOneTotalByteBudget() throws {
        let temporaryDirectory = try makeRegressionDirectory()
        let package = temporaryDirectory.appendingPathComponent("Large.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 6).write(to: package.appendingPathComponent("a"))
        try Data(repeating: 2, count: 6).write(to: package.appendingPathComponent("b"))
        let snapshot = temporaryDirectory.appendingPathComponent("snapshot.rtfd", isDirectory: true)

        XCTAssertThrowsError(
            try VerifiedDirectoryStaging.stage(
                from: package,
                to: snapshot,
                maximumFileBytes: 10,
                maximumTotalBytes: 10,
                maximumEntries: 10,
                describedAs: "the test package"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("size limit"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    }

    func testIgnoredRTFDestinationBetweenSurrogatesPreservesVisibleText() throws {
        let root = try makeRegressionDirectory()
        let rtf = #"{\rtf1\ansi\uc0 A\u-10179{\*\unknown hidden {\uc2\u56832??}\bin3 {}X}\u-8704 B}"#
        let source = root.appendingPathComponent("source.rtf")
        let original = Data(rtf.utf8)
        try original.write(to: source)
        #if os(macOS)
        let reference = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/textutil"),
            arguments: ["-convert", "txt", "-stdout", source.path], currentDirectory: root, captureStandardOutput: true)
        XCTAssertEqual(reference.status, 0)
        XCTAssertEqual(reference.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "A😀B")
        #endif
        let result = try RichTextConverter().convert(inputURL: source)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(markdown.trimmingCharacters(in: .whitespacesAndNewlines), "A😀B")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
