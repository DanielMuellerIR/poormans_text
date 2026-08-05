import Foundation
import XCTest
@testable import PoorMansTextCore

final class RichTextConverterTests: XCTestCase {
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
        XCTAssertEqual(result.assets.map(\.lastPathComponent), ["image01.png", "image02.png"])
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

    func testConvertsRealRTFWithoutChangingTextOrEmbeddedImage() throws {
        try requirePandoc()
        let fixture = try FixtureFactory.createRichRTF(in: temporaryDirectory)
        let sourceBefore = try Data(contentsOf: fixture.fileURL)

        let result = try RichTextConverter().convert(inputURL: fixture.fileURL)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), sourceBefore)
        XCTAssertEqual(result.outputDirectory.lastPathComponent, "Example ä-markdown")
        XCTAssertEqual(result.markdownFile.lastPathComponent, "Example ä.md")
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertEqual(result.assets.first?.lastPathComponent, "image01.png")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.assets.first)), fixture.imageData)
        XCTAssertEqual(
            result.warnings,
            ["Chromatic text colors in RTF cannot be represented and were not preserved."]
        )
        XCTAssertTrue(markdown.contains("**bold**"))
        XCTAssertTrue(markdown.contains("*italic*"))
        XCTAssertTrue(markdown.contains("[example](https://example.com/path)"))
        XCTAssertTrue(
            markdown.contains("Purple text remains readable.\n\nAfter the blank line."),
            markdown
        )
        XCTAssertFalse(markdown.contains("\n  \n"), markdown)
        XCTAssertTrue(markdown.contains("-   First item") || markdown.contains("- First item"))
        XCTAssertTrue(markdown.contains("-   Second item") || markdown.contains("- Second item"))
        XCTAssertEqual(markdown.components(separatedBy: "Purple text").count - 1, 1)
        XCTAssertEqual(markdown.components(separatedBy: "![").count - 1, 1)
        XCTAssertTrue(markdown.contains("images/"))
        XCTAssertFalse(markdown.contains("file:///"))

        let boldRange = try XCTUnwrap(markdown.range(of: "**bold**"))
        let imageRange = try XCTUnwrap(markdown.range(of: "![", range: boldRange.upperBound..<markdown.endIndex))
        let italicRange = try XCTUnwrap(markdown.range(of: "*italic*"))
        XCTAssertLessThan(imageRange.lowerBound, italicRange.lowerBound)
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
        XCTAssertEqual(result.assets.map(\.lastPathComponent), ["image01.png", "image02.png"])
        let convertedImageData = try result.assets.map { try Data(contentsOf: $0) }
        XCTAssertEqual(Set(convertedImageData), Set(fixture.imageData))
    }

    func testWarnsAboutEveryAttachmentMissingFromGeneratedHTML() throws {
        try requirePandoc()
        let inputURL = try FixtureFactory.createMinimalRTFD(in: temporaryDirectory)
        try Data("first".utf8).write(to: inputURL.appendingPathComponent("first.bin"))
        try Data("second".utf8).write(to: inputURL.appendingPathComponent("second.dat"))

        let result = try RTFDConverter().convert(inputURL: inputURL)

        XCTAssertEqual(
            result.warnings,
            [
                "Attachment was not represented in the generated Markdown: first.bin",
                "Attachment was not represented in the generated Markdown: second.dat",
            ]
        )
    }

    func testMarksChromaticTextAndUsesWhitespaceHardBreaks() throws {
        try requirePandoc()
        let inputURL = try FixtureFactory.createColoredRTFD(in: temporaryDirectory)

        let result = try RTFDConverter().convert(inputURL: inputURL)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertTrue(markdown.contains("**Plain** ==**Purple one**=="))
        XCTAssertTrue(markdown.contains("==**Purple two**=="))
        XCTAssertTrue(markdown.contains("**Gray**"))
        XCTAssertFalse(markdown.contains("==**Gray**=="))
        XCTAssertTrue(markdown.components(separatedBy: "\n").contains("  "))
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
            guard case ConversionError.invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsRTFWithoutRTFHeader() throws {
        let inputURL = temporaryDirectory.appendingPathComponent("Broken.rtf")
        try Data("plain text".utf8).write(to: inputURL)

        XCTAssertThrowsError(try RichTextConverter().convert(inputURL: inputURL)) { error in
            guard case ConversionError.invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testKeepsRTFParagraphsSeparate() throws {
        try requirePandoc()
        let inputURL = temporaryDirectory.appendingPathComponent("Paragraphs.rtf")
        try Data(#"{\rtf1\ansi First paragraph\par Second paragraph\par}"#.utf8)
            .write(to: inputURL)

        let result = try RichTextConverter().convert(inputURL: inputURL)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertTrue(markdown.contains("First paragraph\n\nSecond paragraph"))
        XCTAssertFalse(markdown.contains("First paragraph  \nSecond paragraph"))
    }

    func testRepairsEscapedNewlineParagraphsAndKeepsRTFListsTight() throws {
        try requirePandoc()
        let inputURL = temporaryDirectory.appendingPathComponent("Escaped newlines.rtf")
        let rtf = #"""
        {\rtf1\ansi
        First paragraph\
        Second paragraph\
        \pard\tx220\tx720\li720\fi-720
        \ls1\ilvl0{\listtext\u8226  }First item\
        \ls1\ilvl0{\listtext\u8226  }Second item\
        }
        """#
        try Data(rtf.utf8).write(to: inputURL)

        let result = try RichTextConverter().convert(inputURL: inputURL)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertTrue(
            markdown.contains("First paragraph\n\nSecond paragraph"),
            "Escaped RTF paragraph boundaries were lost:\n\(markdown)"
        )
        XCTAssertFalse(
            markdown.contains("First item\n\n") || markdown.contains("First item\n  \n"),
            "Pandoc produced a loose list:\n\(markdown)"
        )
        XCTAssertTrue(markdown.contains("First item"))
        XCTAssertTrue(markdown.contains("Second item"))
    }

    func testRTFPreparationDoesNotTreatEscapedBackslashAsParagraphControl() {
        let source = Data(#"{\rtf1 literal \\par trailing \par}"#.utf8)

        let prepared = RichTextAdapter().preservingEmptyRTFParagraphs(
            in: source,
            marker: "EMPTY"
        )

        XCTAssertEqual(prepared, source)
    }

    func testRTFPreparationSkipsBinaryPayloadContainingParagraphBytes() {
        let prefix = Data(#"{\rtf1\bin8 "#.utf8)
        let binaryPayload = Data(#"\par\par"#.utf8)
        let suffix = Data(#"\par\par}"#.utf8)
        var source = prefix
        source.append(binaryPayload)
        source.append(suffix)

        let prepared = RichTextAdapter().preservingEmptyRTFParagraphs(
            in: source,
            marker: "EMPTY"
        )
        let text = String(decoding: prepared, as: UTF8.self)

        XCTAssertTrue(prepared.starts(with: prefix + binaryPayload))
        XCTAssertEqual(text.components(separatedBy: "EMPTY").count - 1, 1)
    }

    func testRTFPreparationHandlesControlsAtDataBoundaries() {
        let adapter = RichTextAdapter()
        let trailingBackslash = Data([0x7B, 0x5C])
        let trailingControl = Data(#"{\rtf1\par"#.utf8)

        XCTAssertEqual(
            adapter.preservingEmptyRTFParagraphs(in: trailingBackslash, marker: "EMPTY"),
            trailingBackslash
        )
        XCTAssertEqual(
            adapter.preservingEmptyRTFParagraphs(in: trailingControl, marker: "EMPTY"),
            trailingControl
        )
    }

    func testListParagraphUnwrapIsLimitedToSinglePlainParagraph() {
        let adapter = RichTextAdapter()

        XCTAssertEqual(
            adapter.unwrappingListParagraphs(in: "<ul><li class=\"x\"><p>Item</p></li></ul>"),
            "<ul><li class=\"x\">Item</li></ul>"
        )
        XCTAssertEqual(
            adapter.unwrappingListParagraphs(in: "<li><p>First</p><p>Second</p></li>"),
            "<li><p>First</p><p>Second</p></li>"
        )
    }

    func testKeepsRealRTFDParagraphsSeparate() throws {
        try requirePandoc()
        let inputURL = try FixtureFactory.createTwoParagraphRTFD(in: temporaryDirectory)
        let sourceBefore = try Data(contentsOf: inputURL.appendingPathComponent("TXT.rtf"))

        let result = try RTFDConverter().convert(inputURL: inputURL)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(markdown, "First paragraph\n\nSecond paragraph\n")
        XCTAssertEqual(
            try Data(contentsOf: inputURL.appendingPathComponent("TXT.rtf")),
            sourceBefore
        )
    }

    func testKeepsRealRTFDManualLineBreakDistinctFromParagraph() throws {
        try requirePandoc()
        let inputURL = try FixtureFactory.createManualLineBreakRTFD(in: temporaryDirectory)
        let sourceBefore = try Data(contentsOf: inputURL.appendingPathComponent("TXT.rtf"))

        let result = try RTFDConverter().convert(inputURL: inputURL)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(markdown, "First line  \nSecond line\n\nThird paragraph\n")
        XCTAssertEqual(
            try Data(contentsOf: inputURL.appendingPathComponent("TXT.rtf")),
            sourceBefore
        )
    }

    func testPreservesEmptyRTFParagraph() throws {
        try requirePandoc()
        let inputURL = temporaryDirectory.appendingPathComponent("Empty paragraph.rtf")
        try Data(#"{\rtf1\ansi First\par\par Third\par}"#.utf8).write(to: inputURL)

        let result = try RichTextConverter().convert(inputURL: inputURL)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(markdown.components(separatedBy: "\n").filter { $0 == "  " }.count, 1)
        XCTAssertTrue(markdown.contains("First\n  \nThird"))
    }

    func testWarnsWhenRTFHighlightColorCannotBePreserved() throws {
        try requirePandoc()
        let inputURL = try FixtureFactory.createHighlightedRTF(in: temporaryDirectory)

        let result = try RichTextConverter().convert(inputURL: inputURL)
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertTrue(markdown.contains("Highlighted"))
        XCTAssertEqual(
            result.warnings,
            ["Chromatic text colors in RTF cannot be represented and were not preserved."]
        )
    }

    func testDoesNotWarnForAchromaticRTFHighlight() throws {
        try requirePandoc()
        let inputURL = temporaryDirectory.appendingPathComponent("Gray highlight.rtf")
        let rtf = #"{\rtf1\ansi{\colortbl;\red128\green128\blue128;}\highlight1 Gray\highlight0}"#
        try Data(rtf.utf8).write(to: inputURL)

        let result = try RichTextConverter().convert(inputURL: inputURL)

        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testReportsUnreadableRTFAsFileSystemFailure() throws {
        let inputURL = try FixtureFactory.createMinimalRTF(in: temporaryDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: inputURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
        }

        XCTAssertThrowsError(try RichTextConverter().convert(inputURL: inputURL)) { error in
            guard case ConversionError.fileSystemFailure = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCleansTemporaryOutputWhenPandocFails() throws {
        let inputURL = try FixtureFactory.createMinimalRTF(in: temporaryDirectory)
        let sourceBefore = try Data(contentsOf: inputURL)
        let outputURL = temporaryDirectory.appendingPathComponent("Failed output", isDirectory: true)
        let fakePandoc = temporaryDirectory.appendingPathComponent("fake-pandoc")
        try Data("#!/bin/sh\nexit 42\n".utf8).write(to: fakePandoc)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePandoc.path)

        XCTAssertThrowsError(
            try RichTextConverter().convert(
                inputURL: inputURL,
                outputDirectory: outputURL,
                pandocExecutable: fakePandoc
            )
        ) { error in
            guard case ConversionError.pandocFailed(status: 42, message: _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: inputURL), sourceBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix(".poormans-text-") }
        XCTAssertTrue(leftovers.isEmpty, "Temporary conversion directories remain: \(leftovers)")
    }

    func testRefusesExistingRTFOutputWithoutChangingSourceOrTarget() throws {
        let inputURL = try FixtureFactory.createMinimalRTF(in: temporaryDirectory)
        let sourceBefore = try Data(contentsOf: inputURL)
        let outputURL = temporaryDirectory.appendingPathComponent("Existing RTF", isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)
        let markerURL = outputURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: markerURL)

        XCTAssertThrowsError(
            try RichTextConverter().convert(inputURL: inputURL, outputDirectory: outputURL)
        ) { error in
            guard case ConversionError.outputAlreadyExists = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: inputURL), sourceBefore)
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "keep")
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
