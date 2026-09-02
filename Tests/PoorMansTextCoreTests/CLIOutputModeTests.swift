import Foundation
import XCTest
@testable import PoorMansTextCore

/// Die Ausgabewege der CLI jenseits des Ergebnisordners: `--stdout`,
/// `--frontmatter` und `--textbundle`. Bilder ohne OCR brauchen weder Pandoc
/// noch Vision, deshalb laufen diese Tests überall.
final class CLIOutputModeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLIOutputTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStandardOutputPrintsTheMarkdownAndLeavesNoFolderBehind() throws {
        let image = try copyImage(to: "Bild.png")

        let result = try runCLI(["--stdout", "--image-ocr", "off", image.path])

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.hasPrefix("# Bild"), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains("](images/image01.png)"), result.standardOutput)
        XCTAssertTrue(
            result.standardError.contains("1 image asset(s) were not written; --stdout emits text only."),
            result.standardError
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Bild.png"])
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        ).filter { $0.hasPrefix("PoorMansTextImport-") }
        XCTAssertTrue(leftovers.isEmpty, "temporary output was not removed: \(leftovers)")
    }

    func testStandardOutputRejectsConflictingOptionsBeforeConverting() throws {
        let image = try copyImage(to: "Bild.png")
        let second = try copyImage(to: "Zwei.png")
        let folder = root.appendingPathComponent("Ordner", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        // Im JSON-Modus kommt auch der Aufruffehler als JSON auf stdout.
        let jsonConflict = try runCLI(["--stdout", "--json", image.path])
        XCTAssertEqual(jsonConflict.status, 64)
        XCTAssertEqual(try decodeJSON(jsonConflict.standardOutput)["ok"] as? Bool, false)

        for arguments in [
            ["--stdout", "--output", root.appendingPathComponent("out").path, image.path],
            ["--stdout", "--textbundle", image.path],
            ["--stdout", image.path, second.path],
            ["--stdout", folder.path],
            ["--formats", "--stdout"],
            ["--formats", "--frontmatter"],
            ["--formats", "--textbundle"],
        ] {
            let result = try runCLI(arguments)
            XCTAssertEqual(result.status, 64, arguments.joined(separator: " "))
            XCTAssertTrue(result.standardOutput.isEmpty, arguments.joined(separator: " "))
            XCTAssertTrue(result.standardError.hasPrefix("Error: "), result.standardError)
        }
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
            ["Bild.png", "Zwei.png", "Ordner"]
        )
    }

    func testTextbundleIsWrittenNextToTheSourceAndReportedInJSON() throws {
        let image = try copyImage(to: "Bild.png")

        let result = try runCLI(["--json", "--textbundle", "--image-ocr", "off", image.path])

        XCTAssertEqual(result.status, 0, result.standardError)
        let json = try decodeJSON(result.standardOutput)
        let bundle = root.appendingPathComponent("Bild.textbundle")
        XCTAssertEqual(json["outputDirectory"] as? String, bundle.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            json["markdownFile"] as? String,
            bundle.appendingPathComponent("text.md").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            json["assets"] as? [String],
            [bundle.appendingPathComponent("assets/image01.png").resolvingSymlinksInPath().path]
        )
        XCTAssertEqual(json["metadata"] as? [String: String], [:])

        // Ein Zielname ohne die Endung ist ein Aufruffehler, kein Dateisystemfehler.
        let named = try runCLI([
            "--textbundle", "--image-ocr", "off", "--output", root.appendingPathComponent("Ziel").path, image.path,
        ])
        XCTAssertEqual(named.status, 64, named.standardError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ziel").path))
    }

    func testFrontmatterOptionIsAcceptedAndReportsMissingMetadata() throws {
        let image = try copyImage(to: "Bild.png")

        let result = try runCLI(["--json", "--frontmatter", "--image-ocr", "off", image.path])

        XCTAssertEqual(result.status, 0, result.standardError)
        let json = try decodeJSON(result.standardOutput)
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertTrue(warnings.contains { $0.contains("no frontmatter was written") }, warnings.joined())
    }

    @discardableResult
    private func copyImage(to relativePath: String) throws -> URL {
        let target = root.appendingPathComponent(relativePath)
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
