import Foundation
import XCTest
@testable import PoorMansTextCore

final class WordProcessingAdapterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextWordProcessingTests-\(UUID().uuidString)",
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

    func testDetectsDOCXODTAndDOCFromContentsAcrossIndependentProducers() throws {
        let converter = DocumentConverter()
        let fixtures: [(String, InputFormat)] = [
            ("pandoc.docx", .docx),
            ("libreoffice.docx", .docx),
            ("textutil.docx", .docx),
            ("pandoc.odt", .odt),
            ("libreoffice.odt", .odt),
            ("textutil.odt", .odt),
            ("libreoffice.doc", .doc),
            ("textutil.doc", .doc),
        ]

        for (name, expectedFormat) in fixtures {
            let renamedURL = temporaryDirectory.appendingPathComponent(
                "Renamed-\(UUID().uuidString).data"
            )
            try FileManager.default.copyItem(at: fixture(name), to: renamedURL)

            XCTAssertEqual(
                try converter.detectFormat(at: renamedURL),
                expectedFormat,
                "Failed to detect \(name)"
            )
        }
    }

    func testDOCXAndODTMatchDirectPandocOutputAndPreserveMediaFromTwoProducers() throws {
        try requirePandoc()
        let embeddedImage = try Data(contentsOf: fixture("fixture.png"))

        for format in [InputFormat.docx, .odt] {
            for producer in ["pandoc", "libreoffice"] {
                let sourceURL = fixture("\(producer).\(format.rawValue)")
                let sourceBefore = try Data(contentsOf: sourceURL)
                let outputURL = temporaryDirectory.appendingPathComponent(
                    "\(producer)-\(format.rawValue)-result"
                )
                let result = try DocumentConverter().convert(
                    ConversionRequest(
                        inputURL: sourceURL,
                        destination: .directory(outputURL)
                    )
                )
                let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
                let directMarkdown = try convertDirectlyWithPandoc(
                    sourceURL,
                    format: format,
                    name: "\(producer)-\(format.rawValue)-direct.md"
                )

                XCTAssertEqual(result.format, format)
                XCTAssertEqual(result.diagnostics, [])
                XCTAssertEqual(
                    normalizeImageReferences(in: markdown),
                    normalizeImageReferences(in: directMarkdown),
                    "\(producer) \(format.rawValue) differs from direct Pandoc output"
                )
                XCTAssertTrue(markdown.contains("# Fixture heading ä"))
                XCTAssertTrue(markdown.contains("**bold text**"))
                XCTAssertTrue(markdown.contains("*italic text*"))
                XCTAssertTrue(markdown.contains("[external link](https://example.com/document)"))
                XCTAssertTrue(markdown.contains("Footnote content remains readable."))
                XCTAssertTrue(markdown.contains("| Äpfel"))
                XCTAssertEqual(result.assets.count, 1)
                XCTAssertEqual(
                    try Data(contentsOf: try XCTUnwrap(result.assets.first)),
                    embeddedImage
                )
                XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
            }
        }
    }

    func testDOCImportsTwoRealBinaryFixturesWithoutChangingSources() throws {
        try requirePandoc()

        for producer in ["textutil", "libreoffice"] {
            let sourceURL = fixture("\(producer).doc")
            let sourceBefore = try Data(contentsOf: sourceURL)
            let result = try DocumentConverter().convert(
                ConversionRequest(
                    inputURL: sourceURL,
                    destination: .directory(
                        temporaryDirectory.appendingPathComponent("\(producer)-doc-result")
                    )
                )
            )
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

            XCTAssertEqual(result.format, .doc)
            XCTAssertEqual(result.diagnostics.map(\.code), ["legacyWord.potentialLoss"])
            XCTAssertTrue(markdown.contains("Fixture heading ä"))
            XCTAssertTrue(markdown.contains("First list item"))
            XCTAssertTrue(markdown.contains("Äpfel"))
            XCTAssertTrue(markdown.contains("Grüße aus Köln"))
            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
        }
    }

    func testContentDetectionKeepsARealXLSOutOfTheDOCAdapter() throws {
        let xlsURL = spreadsheetFixture("not-word.xls")

        XCTAssertEqual(try DocumentConverter().detectFormat(at: xlsURL), .xls)

        let falseDOC = temporaryDirectory.appendingPathComponent("Spreadsheet.doc")
        try FileManager.default.copyItem(at: xlsURL, to: falseDOC)
        XCTAssertEqual(try DocumentConverter().detectFormat(at: falseDOC), .xls)
    }

    func testInspectionReportsDOCXAndODTAnnotationsAndTrackedChanges() throws {
        let sourceURL = fixture("annotated.docx")
        let inspection = try DocumentConverter().inspect(sourceURL)

        XCTAssertEqual(inspection.format, .docx)
        XCTAssertEqual(
            inspection.expectedWarnings.map(\.code),
            [
                "wordProcessing.commentsNotPreserved",
                "wordProcessing.changesAccepted",
            ]
        )

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(
                    temporaryDirectory.appendingPathComponent("annotated-result")
                )
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Accepted change"))
        XCTAssertEqual(
            result.diagnostics.map(\.code),
            inspection.expectedWarnings.map(\.code)
        )

        let odtURL = fixture("annotated.odt")
        let odtInspection = try DocumentConverter().inspect(odtURL)
        XCTAssertEqual(odtInspection.format, .odt)
        XCTAssertEqual(
            odtInspection.expectedWarnings.map(\.code),
            [
                "wordProcessing.commentsNotPreserved",
                "openDocument.changesNotPreserved",
            ]
        )
        let odtResult = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: odtURL,
                destination: .directory(
                    temporaryDirectory.appendingPathComponent("annotated-odt-result")
                )
            )
        )
        XCTAssertTrue(
            try String(contentsOf: odtResult.markdownFile, encoding: .utf8)
                .contains("Annotated ODT text")
        )
        XCTAssertEqual(
            odtResult.diagnostics.map(\.code),
            odtInspection.expectedWarnings.map(\.code)
        )
    }

    func testConvertsGeneratedDOCMAndTemplatePackagesWithTheirLossWarnings() throws {
        try requirePandoc()
        let cases = [
            ("Generated.docm", ZIPFixtureBuilder.docmMainContentType, ["wordProcessing.macrosNotPreserved"]),
            ("Generated.dotx", ZIPFixtureBuilder.dotxMainContentType, ["wordProcessing.templateSemanticsNotPreserved"]),
            (
                "Generated.dotm",
                ZIPFixtureBuilder.dotmMainContentType,
                [
                    "wordProcessing.macrosNotPreserved",
                    "wordProcessing.templateSemanticsNotPreserved",
                ]
            ),
        ]

        for (name, contentType, warningCodes) in cases {
            let sourceURL = try createWordPackageVariant(name: name, contentType: contentType)
            let sourceBefore = try Data(contentsOf: sourceURL)

            let result = try DocumentConverter().convert(
                ConversionRequest(
                    inputURL: sourceURL,
                    destination: .directory(
                        temporaryDirectory.appendingPathComponent("\(name)-result")
                    )
                )
            )

            XCTAssertEqual(result.format, .docx)
            XCTAssertEqual(result.diagnostics.map(\.code), warningCodes)
            XCTAssertTrue(
                try String(contentsOf: result.markdownFile, encoding: .utf8)
                    .contains("Fixture heading ä")
            )
            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
        }
    }

    private func createWordPackageVariant(name: String, contentType: String) throws -> URL {
        let packageDirectory = temporaryDirectory.appendingPathComponent(
            "\(name)-package",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: packageDirectory,
            withIntermediateDirectories: false
        )
        let unpack = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", fixture("pandoc.docx").path, packageDirectory.path],
            currentDirectory: temporaryDirectory
        )
        XCTAssertEqual(unpack.status, 0, unpack.standardError)

        let contentTypesURL = packageDirectory.appendingPathComponent("[Content_Types].xml")
        let original = try String(contentsOf: contentTypesURL, encoding: .utf8)
        let changed = original.replacingOccurrences(
            of: ZIPFixtureBuilder.docxMainContentType,
            with: contentType
        )
        XCTAssertNotEqual(changed, original)
        try Data(changed.utf8).write(to: contentTypesURL, options: .atomic)

        let outputURL = temporaryDirectory.appendingPathComponent(name)
        let pack = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-r", outputURL.path, "."],
            currentDirectory: packageDirectory
        )
        XCTAssertEqual(pack.status, 0, pack.standardError)
        return outputURL
    }

    func testRejectsExternalImagesAndUnsafePackagePathsBeforePublishing() throws {
        for name in ["external-image.docx", "external-image.odt", "unsafe-path.docx"] {
            let sourceURL = fixture(name)
            let sourceBefore = try Data(contentsOf: sourceURL)
            let outputURL = temporaryDirectory.appendingPathComponent("\(name)-result")

            XCTAssertThrowsError(
                try DocumentConverter().convert(
                    ConversionRequest(
                        inputURL: sourceURL,
                        destination: .directory(outputURL)
                    )
                )
            )
            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    /// Der dokumentierte Repro-Fall: Pandoc schreibt einen Code-Block ohne
    /// Sprachangabe eingerückt statt eingezäunt. Vor der Code-Erkennung im
    /// Normalisierer verlor eine Fortsetzungszeile dabei ihren Backslash — stiller
    /// Inhaltsverlust bei einer scheinbar erfolgreichen Umwandlung.
    func testIndentedCodeKeepsItsTrailingBackslashThroughTheDOCXRoundTrip() throws {
        try requirePandoc()
        let source = "Intro:\n\n    gcc -o example example.c \\\n    echo done\n"
        let markdownURL = temporaryDirectory.appendingPathComponent("code.md")
        try Data(source.utf8).write(to: markdownURL)

        let docxURL = temporaryDirectory.appendingPathComponent("code.docx")
        let pandocResult = try ProcessRunner.run(
            executable: try PandocTool.resolve(nil),
            arguments: [
                "--from=gfm", "--to=docx",
                "--output", docxURL.path, markdownURL.path,
            ],
            currentDirectory: temporaryDirectory
        )
        XCTAssertEqual(pandocResult.status, 0, pandocResult.standardError)

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: docxURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("code-result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(markdown.contains("    gcc -o example example.c \\"), markdown)
        XCTAssertTrue(markdown.contains("    echo done"), markdown)
    }

    func testDoesNotTrustWordProcessingFilenameExtensions() throws {
        for fileExtension in ["docx", "odt", "doc"] {
            let sourceURL = temporaryDirectory.appendingPathComponent("False.\(fileExtension)")
            try Data("plain text".utf8).write(to: sourceURL)

            XCTAssertThrowsError(try DocumentConverter().detectFormat(at: sourceURL)) { error in
                guard case ConversionError.invalidInput(_, let format, _) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(format.rawValue, fileExtension)
            }
        }
    }

    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/WordProcessing")
            .appendingPathComponent(name)
    }

    private func spreadsheetFixture(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/Spreadsheets")
            .appendingPathComponent(name)
    }

    private func convertDirectlyWithPandoc(
        _ inputURL: URL,
        format: InputFormat,
        name: String
    ) throws -> String {
        let outputURL = temporaryDirectory.appendingPathComponent(name)
        var arguments = [
            "--sandbox",
            "--from=\(format.rawValue)",
            "--to=gfm-raw_html",
            "--wrap=preserve",
        ]
        if format == .docx {
            arguments.append("--track-changes=accept")
        }
        arguments.append(contentsOf: ["--output", outputURL.path, inputURL.path])
        let result = try ProcessRunner.run(
            executable: try PandocTool.resolve(nil),
            arguments: arguments,
            currentDirectory: temporaryDirectory
        )
        XCTAssertEqual(result.status, 0, result.standardError)
        return MarkdownNormalizer.normalize(
            try String(contentsOf: outputURL, encoding: .utf8)
        )
    }

    private func normalizeImageReferences(in markdown: String) -> String {
        let imageExpression = try! NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\([^)]+\)"#
        )
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        let normalizedImages = imageExpression.stringByReplacingMatches(
            in: markdown,
            range: range,
            withTemplate: "![$1](IMAGE)"
        )
        let footnoteExpression = try! NSRegularExpression(
            pattern: #"(?m)^(\[\^[^\]]+\]:)\s+"#
        )
        return footnoteExpression.stringByReplacingMatches(
            in: normalizedImages,
            range: NSRange(
                normalizedImages.startIndex..<normalizedImages.endIndex,
                in: normalizedImages
            ),
            withTemplate: "$1 "
        )
    }

    private func requirePandoc() throws {
        do {
            _ = try PandocTool.resolve(nil)
        } catch {
            throw XCTSkip("Pandoc is required for word-processing integration tests.")
        }
    }
}
