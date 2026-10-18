import Foundation
import XCTest
@testable import PoorMansTextCore

final class CLIIntegrationTests: XCTestCase {
    func testEPUBOverviewSelectionAndChapterReports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCLIEPUB-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try EPUBSelectionFixture.create(in: root)
        let original = try Data(contentsOf: source)
        let overview = try runCLI(["--json", "--list-chapters", source.path])
        XCTAssertEqual(overview.status, 0, overview.standardError)
        let summary = try JSONDecoder().decode(EPUBContentSummary.self, from: Data(overview.standardOutput.utf8))
        XCTAssertEqual(summary.chapters.map(\.title), ["BetaMarker", "AlphaMarker", "GammaMarker"])
        let run = try runCLI(["--json", "--epub-chapters", "3,1,1", "--report", "--output", root.appendingPathComponent("selected").path, source.path])
        XCTAssertEqual(run.status, 0, run.standardError)
        let response = try decodeJSON(run.standardOutput)
        let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(response["reportFile"] as? String))))
        XCTAssertEqual(report.options.epubChapters?.description, "1,3"); XCTAssertEqual(report.sourceMappings.map { $0.source.chapter }, [1, 3])
        let stdout = try runCLI(["--stdout", "--epub-chapters", "2", source.path])
        XCTAssertEqual(stdout.status, 0, stdout.standardError); XCTAssertTrue(stdout.standardOutput.contains("AlphaMarker")); XCTAssertFalse(stdout.standardOutput.contains("BetaMarker"))
        for flags in [["--epub-chapters", "0"], ["--list-chapters", "--epub-chapters", "1"], ["--list-chapters", "--report"], ["--list-chapters", "--list-slides"]] {
            try assertJSONFailure(flags + ["--json", source.path], expectedStatus: 64)
        }
        for flags in [["--epub-chapters", "1"], ["--list-chapters"]] { try assertJSONFailure(["--formats", "--json"] + flags, expectedStatus: 64) }
        try assertJSONFailure(["--json", "--epub-chapters", "4", "--output", root.appendingPathComponent("never").path, source.path], expectedStatus: 65)
        let csv = root.appendingPathComponent("values.csv"); try Data("Name,Value\nMarker,1\n".utf8).write(to: csv)
        try assertJSONFailure(["--json", "--epub-chapters", "1", csv.path], expectedStatus: 65)
        try assertJSONFailure(["--json", "--list-chapters", csv.path], expectedStatus: 65)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.deletingPathExtension().path + "-markdown"))
    }

    func testPresentationOverviewTextReportsItsDefaultLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCLIOverviewLimit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("many.odp")
        let pages = (1...201).map { "<draw:page><text:p>Title\($0)</text:p></draw:page>" }.joined()
        let xml = "<office:document-content xmlns:office=\"\(PresentationImport.office)\" xmlns:draw=\"\(PresentationImport.draw)\" xmlns:text=\"\(PresentationImport.text)\"><office:body><office:presentation>\(pages)</office:presentation></office:body></office:document-content>"
        try ZIPFixtureBuilder.archive(entries: [.init(name: "mimetype", content: Data("application/vnd.oasis.opendocument.presentation".utf8)), .init(name: "content.xml", content: Data(xml.utf8))]).write(to: source)
        let run = try runCLI(["--list-slides", source.path])
        XCTAssertEqual(run.status, 0, run.standardError)
        XCTAssertEqual(run.standardOutput.split(separator: "\n").count, 200)
        XCTAssertTrue(run.standardError.contains("200 of 201"))
        let json = try runCLI(["--json", "--list-slides", source.path])
        let summary = try JSONDecoder().decode(PresentationContentSummary.self, from: Data(json.standardOutput.utf8))
        XCTAssertEqual(summary.slideCount, 201); XCTAssertEqual(summary.slides.count, 200); XCTAssertTrue(summary.slidesTruncated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["many.odp"])
    }

    func testPresentationOverviewSelectionAndNoteOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCLISlides-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("slides.odp")
        let xml = "<office:document-content xmlns:office=\"\(PresentationImport.office)\" xmlns:draw=\"\(PresentationImport.draw)\" xmlns:text=\"\(PresentationImport.text)\" xmlns:presentation=\"\(PresentationImport.presentationODF)\"><office:body><office:presentation><draw:page><text:p>FirstMarker</text:p></draw:page><draw:page><text:p>SecondMarker</text:p><presentation:notes><text:p>NotesMarker</text:p></presentation:notes></draw:page></office:presentation></office:body></office:document-content>"
        let bytes = try ZIPFixtureBuilder.archive(entries: [.init(name: "mimetype", content: Data("application/vnd.oasis.opendocument.presentation".utf8)), .init(name: "content.xml", content: Data(xml.utf8))]); try bytes.write(to: source)
        let overview = try runCLI(["--json", "--list-slides", source.path])
        XCTAssertEqual(overview.status, 0, overview.standardError)
        let summary = try JSONDecoder().decode(PresentationContentSummary.self, from: Data(overview.standardOutput.utf8))
        XCTAssertEqual(summary.slides.map(\.number), [1, 2]); XCTAssertEqual(summary.slides.map(\.hasNotes), [false, true])
        let destination = root.appendingPathComponent("selected")
        let run = try runCLI(["--json", "--slides", "2,2", "--notes", "off", "--report", "--output", destination.path, source.path])
        XCTAssertEqual(run.status, 0, run.standardError)
        let response = try decodeJSON(run.standardOutput)
        let text = try String(contentsOf: URL(fileURLWithPath: XCTUnwrap(response["markdownFile"] as? String)), encoding: .utf8)
        XCTAssertTrue(text.contains("## Slide 2")); XCTAssertTrue(text.contains("SecondMarker")); XCTAssertFalse(text.contains("FirstMarker")); XCTAssertFalse(text.contains("NotesMarker"))
        let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(response["reportFile"] as? String))))
        XCTAssertEqual(report.options.presentationSelection?.slides?.description, "2"); XCTAssertEqual(report.options.presentationSelection?.includeNotes, false)
        XCTAssertEqual(report.sourceMappings.map { $0.source.slide }, [2])
        let stdout = try runCLI(["--stdout", "--slides", "2", "--notes", "on", source.path])
        XCTAssertEqual(stdout.status, 0, stdout.standardError); XCTAssertTrue(stdout.standardOutput.contains("NotesMarker"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.deletingPathExtension().path + "-markdown"))
        for flags in [["--slides", "0"], ["--notes", "maybe"], ["--list-slides", "--notes", "on"], ["--list-slides", "--list-sheets"], ["--list-slides", "--report"]] {
            try assertJSONFailure(flags + ["--json", source.path], expectedStatus: 64)
        }
        for flags in [["--slides", "1"], ["--notes", "on"], ["--list-slides"]] { try assertJSONFailure(["--formats", "--json"] + flags, expectedStatus: 64) }
        try assertJSONFailure(["--json", "--slides", "3", "--output", root.appendingPathComponent("never").path, source.path], expectedStatus: 65)
        let csv = root.appendingPathComponent("values.csv"); try Data("Name,Value\nMarker,1\n".utf8).write(to: csv)
        try assertJSONFailure(["--json", "--slides", "1", csv.path], expectedStatus: 65)
        try assertJSONFailure(["--json", "--notes", "off", csv.path], expectedStatus: 65)
        try assertJSONFailure(["--json", "--list-slides", csv.path], expectedStatus: 65)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testSpreadsheetOverviewSelectionAndOriginalCoordinates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCLIWorkbook-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try SpreadsheetSelectionFixture.create(in: root)
        for source in sources {
            let overview = try runCLI(["--json", "--list-sheets", source.path])
            XCTAssertEqual(overview.status, 0, overview.standardError)
            let summary = try JSONDecoder().decode(SpreadsheetContentSummary.self, from: Data(overview.standardOutput.utf8))
            XCTAssertEqual(summary.sheets.map(\.index), [1, 2, 3])
            XCTAssertEqual(summary.sheets.map(\.name), ["Visible", "Hidden", "VeryHidden"])
            let destination = root.appendingPathComponent(source.lastPathComponent + "-selected")
            let run = try runCLI(["--json", "--report", "--sheet-name", "Hidden", "--sheet-name", "Hidden", "--cell-range", "D2:E3", "--output", destination.path, source.path])
            XCTAssertEqual(run.status, 0, run.standardError)
            let response = try decodeJSON(run.standardOutput)
            let mappings = try XCTUnwrap(response["sourceMappings"] as? [[String: Any]])
            XCTAssertEqual(mappings.count, 4)
            XCTAssertEqual(Set(mappings.compactMap { ($0["source"] as? [String: Any])?["sheetIndex"] as? Int }), [2])
            XCTAssertEqual(Set(mappings.compactMap { ($0["source"] as? [String: Any])?["cell"] as? String }), ["D2", "E2", "D3", "E3"])
            let stdout = try runCLI(["--stdout", "--sheets", "visible", "--cell-range", "D2", source.path])
            XCTAssertEqual(stdout.status, 0, stdout.standardError)
            XCTAssertTrue(stdout.standardOutput.contains("1204"))
            XCTAssertFalse(stdout.standardOutput.contains("2204"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.deletingPathExtension().path + "-markdown"))
        }
    }

    func testSpreadsheetSelectionRejectsInvalidSyntaxModesAndInputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCLIWorkbookErrors-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SpreadsheetSelectionFixture.create(in: root)[0]
        for arguments in [["--cell-range", "B2:A1"], ["--sheets", "0"], ["--sheet-name", ""], ["--sheet-name", String(repeating: "a", count: 1_025)],
                          ["--sheets", "all", "--sheet-name", "Hidden"], ["--sheet-name", "Hidden", "--sheets", "all"],
                          ["--list-sheets", "--cell-range", "A1"], ["--list-sheets", "--report"]] {
            try assertJSONFailure(arguments + ["--json", source.path], expectedStatus: 64)
        }
        for flag in ["--list-sheets", "--sheets", "--sheet-name", "--cell-range"] {
            let arguments = flag == "--list-sheets" ? [flag] : [flag, flag == "--sheets" ? "all" : flag == "--sheet-name" ? "Hidden" : "A1"]
            try assertJSONFailure(["--formats", "--json"] + arguments, expectedStatus: 64)
        }
        let destination = root.appendingPathComponent("never")
        for flags in [["--sheets", "4"], ["--sheet-name", "missing"]] {
            try assertJSONFailure(flags + ["--json", "--output", destination.path, source.path], expectedStatus: 65)
        }
        let csv = root.appendingPathComponent("values.csv"); try Data("Name,Value\nMarker,1\n".utf8).write(to: csv)
        try assertJSONFailure(["--json", "--sheets", "all", "--output", destination.path, csv.path], expectedStatus: 65)
        try assertJSONFailure(["--json", "--list-sheets", csv.path], expectedStatus: 65)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPDFPageSelectionKeepsSourceNumbersAndWorksWithStdout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCLISelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try PDFSelectionFixture.create(in: root, texts: ["OneMarker", "TwoMarker", "ThreeMarker", "FourMarker"])
        let original = try Data(contentsOf: source)
        let run = try runCLI(["--json", "--report", "--pdf-ocr=off", "--pdf-pages=4,2,2", "--output", root.appendingPathComponent("selected").path, source.path])
        XCTAssertEqual(run.status, 0, run.standardError)
        let json = try decodeJSON(run.standardOutput)
        let markdown = try String(contentsOfFile: XCTUnwrap(json["markdownFile"] as? String), encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Page 2")); XCTAssertTrue(markdown.contains("## Page 4"))
        XCTAssertFalse(markdown.contains("OneMarker")); XCTAssertFalse(markdown.contains("ThreeMarker"))
        let mappings = try XCTUnwrap(json["sourceMappings"] as? [[String: Any]])
        XCTAssertEqual(mappings.compactMap { ($0["source"] as? [String: Any])?["page"] as? Int }, [2, 4])
        let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(json["reportFile"] as? String))))
        XCTAssertEqual(report.options.pdfPages?.description, "2,4")
        let stdout = try runCLI(["--stdout", "--pdf-pages", "2", "--pdf-ocr", "off", "--pdf-layout", "legacy", source.path])
        XCTAssertEqual(stdout.status, 0, stdout.standardError)
        XCTAssertTrue(stdout.standardOutput.contains("## Page 2")); XCTAssertFalse(stdout.standardOutput.contains("FourMarker"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.deletingPathExtension().path + "-markdown"))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPDFPageSelectionRejectsInvalidRangesWrongFormatsAndCatalogMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTCLISelectionError-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try PDFSelectionFixture.create(in: root, texts: ["OneMarker", "TwoMarker"])
        for value in ["", "0", "2-1", "1,,2", "1-"] {
            try assertJSONFailure(["--pdf-pages", value, "--json", source.path], expectedStatus: 64)
        }
        try assertJSONFailure(["--formats", "--pdf-pages", "1", "--json"], expectedStatus: 64)
        let destination = root.appendingPathComponent("never-published")
        try assertJSONFailure(["--json", "--pdf-pages", "3", "--output", destination.path, source.path], expectedStatus: 65)
        let csv = root.appendingPathComponent("values.csv"); try Data("Name,Value\nMarker,42\n".utf8).write(to: csv)
        try assertJSONFailure(["--json", "--pdf-pages", "1", "--output", destination.path, csv.path], expectedStatus: 65)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testReportAndSourceMapOptionsExposePortableProofsAndRejectMeaninglessModes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("values.csv")
        let original = Data("Name,Value\nMarker,42\n".utf8)
        try original.write(to: source)
        for flag in ["--report", "--source-map"] {
            let run = try runCLI(["--json", flag, "--output", root.appendingPathComponent(String(flag.dropFirst(2))).path, source.path])
            XCTAssertEqual(run.status, 0, run.standardError)
            let json = try decodeJSON(run.standardOutput)
            let identity = try XCTUnwrap(json["sourceIdentity"] as? [String: Any])
            XCTAssertEqual(identity["sha256"] as? String, ConversionFileFingerprint.digest(original))
            XCTAssertEqual((json["sourceMappings"] as? [[String: Any]])?.count, 4)
            if flag == "--report" {
                let report = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(json["reportFile"] as? String)))
                XCTAssertFalse(String(decoding: report, as: UTF8.self).contains(root.path))
            } else { XCTAssertNil(json["reportFile"]) }
        }
        for arguments in [["--source-map", source.path], ["--formats", "--source-map"], ["--formats", "--report"],
                          ["--stdout", "--report", source.path], ["--stdout", "--source-map", source.path]] {
            XCTAssertEqual(try runCLI(arguments).status, 64, arguments.joined(separator: " "))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testInformationalOCRDiagnosticsRemainSuccessfulAndMachineReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WordProcessing/fixture.png")
        let original = try Data(contentsOf: input)
        let result = try runCLI(["--json", "--output", root.appendingPathComponent("result").path, input.path])
        XCTAssertEqual(result.status, 0, result.standardError)
        let json = try decodeJSON(result.standardOutput)
        XCTAssertEqual(json["ok"] as? Bool, true)
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertTrue(warnings.contains { $0.contains("Local OCR text was added") })
        let diagnostics = try XCTUnwrap(json["diagnostics"] as? [[String: Any]])
        XCTAssertTrue(diagnostics.contains { $0["code"] as? String == "image.ocrApplied" && $0["kind"] as? String == "information" })
        let groups = try XCTUnwrap(json["diagnosticGroups"] as? [[String: Any]])
        XCTAssertTrue(groups.contains { $0["code"] as? String == "image.ocrApplied" && $0["count"] as? Int == 1 })
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
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
            ["assets", "documents", "input", "markdownFile", "metadata", "ok", "outputDirectory", "version", "warnings"]
        )
        let documents = try XCTUnwrap(successJSON["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents[0]["markdownFile"] as? String, successJSON["markdownFile"] as? String)
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

        // Ein Fehler VOR `--json` kommt ebenfalls als JSON: Ein Wrapper, der
        // `--json` anhängt, bekam hier vorher Text (Roadmap-Punkt, 2026-09-10).
        try assertJSONFailure(["--unknown", "--json"], expectedStatus: 64)
        try assertJSONFailure(["--timeout", "abc", "--json"], expectedStatus: 64)
        try assertJSONFailure(["--pandoc=--json", "--json"], expectedStatus: 64)
        // Nach `--` ist auch ein zweites `--json` eine Eingabe.
        assertTextFailure(try runCLI(["--", "--json", "--json"]), expectedStatus: 66)
    }

    /// Jede Option mit Wert muss ihren Wert wirklich verbrauchen — sonst läse
    /// der Vorabscan ein `--json` an dieser Stelle als Ausgabemodus, obwohl es
    /// ein Pfad oder ein ungültiger Wert ist. Die Liste hier spiegelt
    /// Konvertierungsoptionen aus `valueOptions` in CLIArguments.swift. Die
    /// eigenständige Profilverwaltung wird in CLIProfileTests separat geprüft.
    func testEveryValueOptionConsumesItsValue() throws {
        let valueOptions = [
            "-o", "--output", "--pandoc", "--timeout", "--jobs", "--spreadsheet-format",
            "--image-ocr", "--pdf-ocr", "--pdf-layout", "--ocr-language", "--pdf-pages", "--sheets", "--sheet-name", "--cell-range", "--slides", "--notes", "--epub-chapters",
        ]
        for option in valueOptions {
            let asValue = try runCLI([option, "--json"])
            XCTAssertNotEqual(asValue.status, 0, option)
            XCTAssertTrue(asValue.standardOutput.isEmpty, "\(option) --json wurde als JSON-Modus gelesen: \(asValue.standardOutput)")

            let missing = try runCLI([option])
            XCTAssertEqual(missing.status, 64, option)
            XCTAssertTrue(missing.standardError.contains("Missing value for \(option)."), "\(option): \(missing.standardError)")
        }
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
            if ["ods", "xlsx", "xls", "image", "pdf", "csv", "pptx", "odp", "ipynb"].contains(format) {
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

    func testImageOCROffPreservesOnlyTheAsset() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextCLIImageTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let inputURL = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/WordProcessing/fixture.png")
        let outputURL = temporaryDirectory.appendingPathComponent("result")

        let result = try runCLI([
            "--json", "--image-ocr", "off", "--output", outputURL.path, inputURL.path,
        ])

        XCTAssertEqual(result.status, 0, result.standardError)
        let json = try decodeJSON(result.standardOutput)
        XCTAssertEqual(json["warnings"] as? [String], [])
        let markdown = try String(contentsOf: outputURL.appendingPathComponent("fixture.md"), encoding: .utf8)
        XCTAssertFalse(markdown.contains("## OCR text"), markdown)
        XCTAssertEqual(
            try Data(contentsOf: outputURL.appendingPathComponent("images/image01.png")),
            try Data(contentsOf: inputURL)
        )

        assertTextFailure(
            try runCLI(["--image-ocr", "unknown", inputURL.path]),
            expectedStatus: 64
        )
    }

    func testFormatsRejectsAConversionArgumentInsteadOfGuessing() throws {
        assertTextFailure(try runCLI(["--formats", "Document.rtf"]), expectedStatus: 64)
        assertTextFailure(try runCLI(["--formats", "-o", "out"]), expectedStatus: 64)
        // Auch eine reine Umwandlungsoption gehört nicht in den Katalogmodus:
        // Sie bliebe wirkungslos und der Aufruf endete trotzdem mit 0.
        assertTextFailure(
            try runCLI(["--formats", "--spreadsheet-format", "tsv"]),
            expectedStatus: 64
        )
        assertTextFailure(
            try runCLI(["--formats", "--spreadsheet-format=tsv"]),
            expectedStatus: 64
        )
        assertTextFailure(
            try runCLI(["--formats", "--image-ocr", "off"]),
            expectedStatus: 64
        )
        assertTextFailure(
            try runCLI(["--formats", "--image-ocr=off"]),
            expectedStatus: 64
        )
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
