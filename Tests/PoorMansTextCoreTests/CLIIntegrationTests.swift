import Foundation
import XCTest
@testable import PoorMansTextCore

final class CLIIntegrationTests: XCTestCase {
    func testRTFSuccessAndInvalidDataKeepJSONAndExitSemantics() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLIIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let validInput = try FixtureFactory.createMinimalRTF(in: temporaryDirectory)
        let success = try runCLI(["--json", validInput.path])
        XCTAssertEqual(success.status, 0, success.standardError)
        XCTAssertTrue(success.standardError.isEmpty)
        let successJSON = try decodeJSON(success.standardOutput)
        XCTAssertEqual(
            Set(successJSON.keys),
            ["assets", "input", "markdownFile", "ok", "outputDirectory", "version", "warnings"]
        )
        XCTAssertEqual(successJSON["ok"] as? Bool, true)
        XCTAssertEqual(successJSON["version"] as? String, ProductInfo.version)
        for key in ["input", "outputDirectory", "markdownFile"] {
            let path = try XCTUnwrap(successJSON[key] as? String)
            XCTAssertEqual(path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: temporaryDirectory.appendingPathComponent("Minimal-markdown/Minimal.md").path
            )
        )

        let invalidInput = temporaryDirectory.appendingPathComponent("Invalid.rtf")
        try Data("not rtf".utf8).write(to: invalidInput)
        let failure = try runCLI(["--json", invalidInput.path])
        XCTAssertEqual(failure.status, 65, failure.standardError)
        XCTAssertTrue(failure.standardError.isEmpty)
        let failureJSON = try decodeJSON(failure.standardOutput)
        XCTAssertEqual(Set(failureJSON.keys), ["error", "ok", "version"])
        XCTAssertEqual(failureJSON["ok"] as? Bool, false)
        XCTAssertNotNil(failureJSON["error"] as? String)
    }

    func testJSONFailureExitCodeMatrixRemainsStable() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLIExitTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try assertJSONFailure(["--json", "--unknown"], expectedStatus: 64)
        try assertJSONFailure(
            ["--json", temporaryDirectory.appendingPathComponent("Missing.rtf").path],
            expectedStatus: 66
        )

        let validInput = try FixtureFactory.createMinimalRTF(in: temporaryDirectory)
        try assertJSONFailure(
            [
                "--json",
                "--pandoc", temporaryDirectory.appendingPathComponent("missing-pandoc").path,
                validInput.path,
            ],
            expectedStatus: 69
        )

        let existingOutput = temporaryDirectory.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingOutput, withIntermediateDirectories: false)
        try assertJSONFailure(
            ["--json", "--output", existingOutput.path, validInput.path],
            expectedStatus: 73
        )

        let failingPandoc = temporaryDirectory.appendingPathComponent("failing-pandoc")
        try Data("#!/bin/sh\nexit 42\n".utf8).write(to: failingPandoc)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: failingPandoc.path
        )
        try assertJSONFailure(
            ["--json", "--pandoc", failingPandoc.path, validInput.path],
            expectedStatus: 70
        )

        let unreadableInput = try FixtureFactory.createMinimalRTF(
            in: temporaryDirectory,
            name: "Unreadable.rtf"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadableInput.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unreadableInput.path
            )
        }
        try assertJSONFailure(["--json", unreadableInput.path], expectedStatus: 74)
    }

    func testJSONModeUsesOnlyOptionsRecognizedByParser() throws {
        let inputNamedJSON = try runCLI(["--", "--json"])
        assertTextFailure(inputNamedJSON, expectedStatus: 66)

        let pandocNamedJSON = try runCLI(["--pandoc", "--json"])
        assertTextFailure(pandocNamedJSON, expectedStatus: 64)

        let outputNamedJSON = try runCLI(["--output", "--json"])
        assertTextFailure(outputNamedJSON, expectedStatus: 64)

        try assertJSONFailure(["--json", "--unknown"], expectedStatus: 64)
    }

    func testDOCXUsesTheSameJSONContract() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLIDOCXTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let inputURL = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/WordProcessing/pandoc.docx")
        let outputURL = temporaryDirectory.appendingPathComponent("DOCX result")
        let result = try runCLI([
            "--json",
            "--output", outputURL.path,
            inputURL.path,
        ])

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardError.isEmpty)
        let json = try decodeJSON(result.standardOutput)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual((json["assets"] as? [String])?.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputURL.appendingPathComponent("pandoc.md").path
            )
        )
    }

    /// `--formats` ist der Weg, auf dem ein Host (Fastra) beim Öffnen einer
    /// Datei entscheidet, ob er eine Umwandlung anbietet. Der Aufruf darf
    /// deshalb nie ein Dokument anfassen, nie scheitern und muss die Endungen
    /// mitliefern — sonst müsste der Host eigenes Formatwissen pflegen.
    func testFormatsListingIsSelfContainedAndNeverFails() throws {
        let text = try runCLI(["--formats"])
        XCTAssertEqual(text.status, 0, text.standardError)
        XCTAssertTrue(text.standardError.isEmpty)
        XCTAssertTrue(text.standardOutput.contains("rtfd"))
        XCTAssertTrue(text.standardOutput.contains("package"))
        // Die Textausgabe muss dieselben Werkzeuge nennen wie die JSON-Ausgabe,
        // sonst verschweigt sie etwa, dass DOC neben Pandoc auch textutil braucht.
        let docLine = try XCTUnwrap(
            text.standardOutput.split(separator: "\n").first { $0.hasPrefix("doc ") }
        )
        XCTAssertTrue(docLine.contains("pandoc"), String(docLine))
        XCTAssertTrue(docLine.contains("textutil"), String(docLine))

        let json = try decodeJSON(try runCLI(["--formats", "--json"]).standardOutput)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["version"] as? String, ProductInfo.version)
        let formats = try XCTUnwrap(json["formats"] as? [[String: Any]])
        XCTAssertEqual(
            Set(formats.compactMap { $0["format"] as? String }),
            Set(DocumentConverter().supportedFormats.map(\.rawValue))
        )
        for entry in formats {
            XCTAssertFalse((entry["extensions"] as? [String] ?? []).isEmpty)
            XCTAssertTrue(["file", "package"].contains(entry["container"] as? String ?? ""))
            XCTAssertNotNil(entry["available"] as? Bool)
            XCTAssertTrue(entry.keys.contains("unavailableReason"))
            if entry["available"] as? Bool == true {
                XCTAssertTrue(entry["unavailableReason"] is NSNull)
            }
        }
        let rtfd = try XCTUnwrap(formats.first { $0["format"] as? String == "rtfd" })
        XCTAssertEqual(rtfd["container"] as? String, "package")
        XCTAssertEqual(rtfd["extensions"] as? [String], ["rtfd"])
        let docx = try XCTUnwrap(formats.first { $0["format"] as? String == "docx" })
        XCTAssertEqual(docx["extensions"] as? [String], ["docx", "docm", "dotx", "dotm"])
    }

    func testFormatsReportsMissingToolInsteadOfFailing() throws {
        let result = try runCLI([
            "--formats", "--json",
            "--pandoc", "/nonexistent/pandoc",
        ])
        // Exit 0 trotz fehlendem Pandoc: Die Liste ist die Antwort, nicht der Fehler.
        XCTAssertEqual(result.status, 0, result.standardError)
        let formats = try XCTUnwrap(decodeJSON(result.standardOutput)["formats"] as? [[String: Any]])
        XCTAssertFalse(formats.isEmpty)
        for entry in formats {
            let format = entry["format"] as? String
            if ["ods", "xlsx", "xls"].contains(format) {
                XCTAssertEqual(entry["available"] as? Bool, true)
                XCTAssertTrue(entry["unavailableReason"] is NSNull)
            } else {
                XCTAssertEqual(entry["available"] as? Bool, false)
                XCTAssertNotNil(entry["unavailableReason"] as? String)
            }
        }
    }

    func testSpreadsheetRenderingOptionSelectsEscapedTSV() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLISpreadsheetTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let inputURL = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/Spreadsheets/multisheet.ods")
        let outputURL = temporaryDirectory.appendingPathComponent("result")

        let result = try runCLI([
            "--spreadsheet-format", "tsv", "--output", outputURL.path, inputURL.path,
        ])

        XCTAssertEqual(result.status, 0, result.standardError)
        let markdown = try String(
            contentsOf: outputURL.appendingPathComponent("multisheet.md"),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("```tsv"))
        XCTAssertTrue(markdown.contains(#"First line\nSecond line"#))

        assertTextFailure(
            try runCLI(["--spreadsheet-format", "unknown", inputURL.path]),
            expectedStatus: 64
        )
    }

    func testFormatsRejectsAConversionArgumentInsteadOfGuessing() throws {
        assertTextFailure(try runCLI(["--formats", "Document.rtf"]), expectedStatus: 64)
        assertTextFailure(try runCLI(["--formats", "-o", "out"]), expectedStatus: 64)
    }

    private func runCLI(_ arguments: [String]) throws -> CLIProcessResult {
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
        process.waitUntilExit()

        return CLIProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            standardError: String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private func decodeJSON(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
        )
    }

    private func assertJSONFailure(
        _ arguments: [String],
        expectedStatus: Int32
    ) throws {
        let result = try runCLI(arguments)
        XCTAssertEqual(result.status, expectedStatus, result.standardError)
        XCTAssertTrue(result.standardError.isEmpty)
        let json = try decodeJSON(result.standardOutput)
        XCTAssertEqual(Set(json.keys), ["error", "ok", "version"])
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["version"] as? String, ProductInfo.version)
        XCTAssertNotNil(json["error"] as? String)
    }

    private func assertTextFailure(
        _ result: CLIProcessResult,
        expectedStatus: Int32
    ) {
        XCTAssertEqual(result.status, expectedStatus)
        XCTAssertTrue(result.standardOutput.isEmpty)
        XCTAssertTrue(result.standardError.hasPrefix("Error: "))
        XCTAssertFalse(result.standardError.contains("\"ok\""))
    }

    private struct CLIProcessResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }
}
