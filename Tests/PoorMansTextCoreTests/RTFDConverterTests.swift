import Foundation
import XCTest
@testable import PoorMansTextCore

final class RTFDConverterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextTests-\(UUID().uuidString)",
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

    func testConvertsRealRTFDWithFormattingLinksListsAndImages() throws {
        try requirePandoc()
        let fixture = try FixtureFactory.createRichRTFD(in: temporaryDirectory)

        let result = try RTFDConverter().convert(inputURL: fixture.packageURL)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(result.outputDirectory.lastPathComponent, "Example ä-markdown")
        XCTAssertEqual(result.markdownFile.lastPathComponent, "Example ä.md")
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(markdown.contains("**bold**"))
        XCTAssertTrue(markdown.contains("*italic*"))
        XCTAssertTrue(markdown.contains("[example](https://example.com/path)"))
        XCTAssertTrue(markdown.contains("-   First item") || markdown.contains("- First item"))
        XCTAssertTrue(markdown.contains("-   Second item") || markdown.contains("- Second item"))
        XCTAssertEqual(markdown.components(separatedBy: "![").count - 1, 2)
        XCTAssertTrue(markdown.contains("images/"))
        XCTAssertFalse(markdown.contains("file:///"))

        let boldRange = try XCTUnwrap(markdown.range(of: "**bold**"))
        let firstImageRange = try XCTUnwrap(markdown.range(of: "![", range: boldRange.upperBound..<markdown.endIndex))
        let italicRange = try XCTUnwrap(markdown.range(of: "*italic*"))
        XCTAssertLessThan(firstImageRange.lowerBound, italicRange.lowerBound)

        let outputEntries = try FileManager.default.contentsOfDirectory(
            at: result.outputDirectory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        XCTAssertEqual(outputEntries, ["Example ä.md", "images"])

        let convertedImageData = try result.assets.map { try Data(contentsOf: $0) }
        XCTAssertEqual(Set(convertedImageData), Set(fixture.imageData))
    }

    func testRefusesExistingOutputWithoutChangingIt() throws {
        let inputURL = try FixtureFactory.createMinimalRTFD(in: temporaryDirectory)
        let outputURL = temporaryDirectory.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)
        let markerURL = outputURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: markerURL)

        XCTAssertThrowsError(
            try RTFDConverter().convert(inputURL: inputURL, outputDirectory: outputURL)
        ) { error in
            guard case ConversionError.outputAlreadyExists = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "keep")
    }

    func testKeepsImagesThatRequestedTheSameAttachmentName() throws {
        try requirePandoc()
        let fixture = try FixtureFactory.createDuplicateImageNameRTFD(in: temporaryDirectory)

        let result = try RTFDConverter().convert(inputURL: fixture.packageURL)

        XCTAssertEqual(result.assets.count, 2)
        XCTAssertEqual(Set(result.assets.map(\.lastPathComponent)).count, 2)
        let convertedImageData = try result.assets.map { try Data(contentsOf: $0) }
        XCTAssertEqual(Set(convertedImageData), Set(fixture.imageData))
    }

    func testWarnsAboutAttachmentMissingFromGeneratedHTML() throws {
        try requirePandoc()
        let inputURL = try FixtureFactory.createMinimalRTFD(in: temporaryDirectory)
        try Data("unrepresented".utf8).write(
            to: inputURL.appendingPathComponent("notes.bin")
        )

        let result = try RTFDConverter().convert(inputURL: inputURL)

        XCTAssertEqual(
            result.warnings,
            ["Attachment was not represented in the generated Markdown: notes.bin"]
        )
    }

    func testRejectsOutputInsideInputPackage() throws {
        let inputURL = try FixtureFactory.createMinimalRTFD(in: temporaryDirectory)
        let outputURL = inputURL.appendingPathComponent("Converted", isDirectory: true)

        XCTAssertThrowsError(
            try RTFDConverter().convert(inputURL: inputURL, outputDirectory: outputURL)
        ) { error in
            guard case ConversionError.outputInsideInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testRejectsPackageWithoutTXTRTF() throws {
        let inputURL = temporaryDirectory.appendingPathComponent("Broken.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: inputURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try RTFDConverter().convert(inputURL: inputURL)) { error in
            guard case ConversionError.invalidRTFD = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsMissingRequestedPandoc() throws {
        let inputURL = try FixtureFactory.createMinimalRTFD(in: temporaryDirectory)
        let missingPandoc = temporaryDirectory.appendingPathComponent("missing-pandoc")

        XCTAssertThrowsError(
            try RTFDConverter().convert(
                inputURL: inputURL,
                pandocExecutable: missingPandoc
            )
        ) { error in
            guard case ConversionError.pandocNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func requirePandoc() throws {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]
        try XCTSkipUnless(
            candidates.contains(where: FileManager.default.isExecutableFile),
            "Pandoc is required for the RTFD integration test."
        )
    }
}
