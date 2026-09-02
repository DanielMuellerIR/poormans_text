import Foundation
import XCTest
@testable import PoorMansTextCore

/// Mehrere Eingaben oder ein Ordner: Die CLI wandelt alles nacheinander um,
/// hält bei einem Fehler nicht an und meldet eine Liste. Der bisherige
/// Einzelweg bleibt dabei unverändert, weil Fastra sich auf ihn verlässt.
/// Bilder mit abgeschalteter OCR brauchen weder Pandoc noch Vision, deshalb
/// laufen diese Tests überall.
final class CLIBatchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLIBatchTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSeveralInputsProduceAListAndTheFirstFailureSetsTheExitCode() throws {
        let first = try copyImage(to: "Eins.png")
        let broken = root.appendingPathComponent("Kaputt.png")
        try Data("not a png".utf8).write(to: broken)
        let second = try copyImage(to: "Zwei.png")

        let result = try runCLI([
            "--json", "--image-ocr", "off", first.path, broken.path, second.path,
        ])

        XCTAssertEqual(result.status, 65, result.standardError)
        XCTAssertTrue(result.standardError.isEmpty)
        let json = try decodeJSON(result.standardOutput)
        XCTAssertEqual(Set(json.keys), ["ok", "results", "version"])
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["version"] as? String, ProductInfo.version)
        let results = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map { $0["ok"] as? Bool }, [true, false, true])
        XCTAssertEqual(
            Set(results[0].keys),
            ["assets", "input", "markdownFile", "ok", "outputDirectory", "warnings"]
        )
        XCTAssertEqual(Set(results[1].keys), ["error", "input", "ok"])
        XCTAssertEqual(results[1]["input"] as? String, broken.resolvingSymlinksInPath().path)
        // Der Fehler in der Mitte hat die dritte Eingabe nicht verhindert.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Zwei-markdown/Zwei.md").path
            )
        )
    }

    func testAFolderIsConvertedRecursivelyAndOutputMirrorsItsStructure() throws {
        try copyImage(to: "Eingang/Deckblatt.png")
        try copyImage(to: "Eingang/Anhang/Foto.jpg")
        try Data("plain".utf8).write(to: root.appendingPathComponent("Eingang/Notiz.txt"))
        let output = root.appendingPathComponent("Ergebnis")

        let result = try runCLI([
            "--image-ocr", "off", "--output", output.path, root.appendingPathComponent("Eingang").path,
        ])

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardError.isEmpty)
        XCTAssertEqual(
            result.standardOutput.split(separator: "\n").map(String.init),
            [
                output.appendingPathComponent("Anhang/Foto-markdown").path,
                output.appendingPathComponent("Deckblatt-markdown").path,
            ]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: output.appendingPathComponent("Anhang/Foto-markdown/Foto.md").path
            )
        )

        // Ein zweiter Lauf in denselben Ordner darf nichts überschreiben: Beide
        // Ziele existieren schon, also beide scheitern mit Kollision (73).
        let second = try runCLI([
            "--json", "--image-ocr", "off", "--output", output.path,
            root.appendingPathComponent("Eingang").path,
        ])
        XCTAssertEqual(second.status, 73, second.standardError)
        let results = try XCTUnwrap(decodeJSON(second.standardOutput)["results"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["ok"] as? Bool }, [false, false])
    }

    func testAFolderWithoutDocumentsAndAMissingOutputParentFailBeforeConverting() throws {
        let empty = root.appendingPathComponent("Leer", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let emptyResult = try runCLI(["--json", empty.path])
        XCTAssertEqual(emptyResult.status, 66, emptyResult.standardError)
        let emptyJSON = try decodeJSON(emptyResult.standardOutput)
        XCTAssertEqual(Set(emptyJSON.keys), ["error", "ok", "version"])

        let image = try copyImage(to: "Bild.png")
        let missingParent = root.appendingPathComponent("fehlt/Ergebnis")
        let parentResult = try runCLI([
            "--image-ocr", "off", "--output", missingParent.path, image.path, image.path,
        ])
        XCTAssertEqual(parentResult.status, 73, parentResult.standardError)
        XCTAssertTrue(parentResult.standardOutput.isEmpty)
        XCTAssertTrue(parentResult.standardError.hasPrefix("Error: "))
    }

    func testTextModeReportsEachFailureAndASummaryOnStandardError() throws {
        let image = try copyImage(to: "Bild.png")
        let broken = root.appendingPathComponent("Kaputt.png")
        try Data("not a png".utf8).write(to: broken)

        let result = try runCLI(["--image-ocr", "off", image.path, broken.path])

        XCTAssertEqual(result.status, 65)
        XCTAssertEqual(
            result.standardOutput.trimmingCharacters(in: .newlines),
            root.appendingPathComponent("Bild-markdown").path
        )
        XCTAssertTrue(result.standardError.contains("Error: \(broken.path): "), result.standardError)
        XCTAssertTrue(result.standardError.hasSuffix("Error: 1 of 2 inputs failed.\n"), result.standardError)
    }

    @discardableResult
    private func copyImage(to relativePath: String) throws -> URL {
        let target = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png"),
            to: target
        )
        return target
    }

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, standardOutput: String, standardError: String) {
        let executable = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("poormans-text")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: outputData, encoding: .utf8) ?? "",
            String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    private func decodeJSON(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
        )
    }
}
