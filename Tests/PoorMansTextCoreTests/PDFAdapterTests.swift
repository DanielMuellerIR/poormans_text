import AppKit
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import PoorMansTextCore

final class PDFAdapterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextPDF-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testConvertsARealTwoPagePDFAndKeepsTheSourceBytes() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Reference.pdf")
        try createPDF(
            pages: ["First page has enough embedded text.", "Second page has enough embedded text."],
            at: sourceURL
        )
        let sourceBefore = try Data(contentsOf: sourceURL)

        let inspection = try DocumentConverter().inspect(sourceURL)
        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(inspection.format, .pdf)
        XCTAssertEqual(inspection.expectedWarnings.map(\.code), ["pdf.layoutNotPreserved"])
        XCTAssertEqual(result.format, .pdf)
        XCTAssertEqual(result.diagnostics.map(\.code), ["pdf.layoutNotPreserved"])
        XCTAssertTrue(markdown.contains("# Reference"), markdown)
        XCTAssertTrue(markdown.contains("## Page 1"), markdown)
        XCTAssertTrue(markdown.contains("First page has enough embedded text."), markdown)
        XCTAssertTrue(markdown.contains("## Page 2"), markdown)
        XCTAssertTrue(markdown.contains("Second page has enough embedded text."), markdown)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
    }

    func testDetectsARealPDFWithoutRelyingOnItsFilenameExtension() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("input.data")
        try createPDF(pages: ["A PDF with a nonstandard filename still has embedded text."], at: sourceURL)

        XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), .pdf)
    }

    func testTreatsEmbeddedPDFTextAsLiteralMarkdown() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("[*Literal*].pdf")
        try createPDF(
            pages: ["### [untrusted] *PDF text* must not become Markdown."],
            at: sourceURL
        )

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("literal-result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertTrue(
            markdown.contains("\\### \\[untrusted\\] \\*PDF text\\* must not become Markdown."),
            markdown
        )
        XCTAssertTrue(markdown.hasPrefix("# \\[\\*Literal\\*\\]"), markdown)
    }

    func testRejectsAFileNamedPDFWithoutAPDFSignature() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Invalid.pdf")
        try Data("not a PDF".utf8).write(to: sourceURL)

        XCTAssertThrowsError(try DocumentConverter().inspect(sourceURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("PDF signature"), error.localizedDescription)
        }
    }

    func testRejectsAPasswordProtectedPDFBeforeConversion() throws {
        let plainURL = temporaryDirectory.appendingPathComponent("Plain.pdf")
        let encryptedURL = temporaryDirectory.appendingPathComponent("Protected.pdf")
        try createPDF(pages: ["This source is encrypted after creation."], at: plainURL)
        let document = try XCTUnwrap(PDFDocument(url: plainURL))

        XCTAssertTrue(
            document.write(
                to: encryptedURL,
                withOptions: [
                    .userPasswordOption: "secret",
                    .ownerPasswordOption: "owner",
                ]
            )
        )
        XCTAssertThrowsError(try DocumentConverter().inspect(encryptedURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("password-protected"))
        }
    }

    func testRejectsMoreThanTheSupportedNumberOfPDFPages() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("ManyPages.pdf")
        try createPDF(pages: Array(repeating: "", count: 1_001), at: sourceURL)

        XCTAssertThrowsError(try DocumentConverter().inspect(sourceURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("page limit"), error.localizedDescription)
        }
    }

    func testRejectsOCRPagesThatExceedTheSharedPixelBudget() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("ManyScans.pdf")
        try createPDF(pages: Array(repeating: "", count: 34), at: sourceURL)

        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(
                    inputURL: sourceURL,
                    destination: .directory(temporaryDirectory.appendingPathComponent("many-scans-result"))
                )
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("pixel budget"), error.localizedDescription)
        }
    }

    func testBlankPDFPageUsesLocalOCRAndMarksMissingText() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Scanned.pdf")
        try createPDF(pages: [""], at: sourceURL)

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("scanned-result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(
            result.diagnostics.map(\.code),
            ["pdf.layoutNotPreserved", "pdf.ocrApplied", "pdf.pageTextUnavailable"]
        )
        XCTAssertTrue(markdown.contains("_No text could be extracted from this page._"), markdown)
    }

    func testKeepsShortEmbeddedTextWhenLocalOCRFindsNothing() throws {
        // Weisse Schrift auf dem weissen Rendergrund: PDFKit liefert den
        // Seitentext, Vision sieht auf dem gerenderten Bild nichts. Weil der
        // Text unter 20 Zeichen bleibt, plant der Adapter fuer diese Seite OCR
        // — und darf den bereits gelesenen Text dabei nicht verlieren.
        let sourceURL = temporaryDirectory.appendingPathComponent("FaintText.pdf")
        try createPDF(pages: ["Chapter 1"], at: sourceURL, foregroundColor: .white)

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("faint-result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertTrue(markdown.contains("Chapter 1"), markdown)
        XCTAssertFalse(
            markdown.contains("_No text could be extracted from this page._"),
            markdown
        )
        XCTAssertEqual(
            result.diagnostics.map(\.code),
            ["pdf.layoutNotPreserved", "pdf.ocrApplied"]
        )
    }

    private func createPDF(
        pages: [String],
        at url: URL,
        foregroundColor: NSColor = .black
    ) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw FixtureError("could not create the PDF output")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FixtureError("could not create the PDF context")
        }
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 14),
                        .foregroundColor: foregroundColor,
                    ]
                ).draw(at: CGPoint(x: 72, y: 720))
                NSGraphicsContext.restoreGraphicsState()
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private struct FixtureError: LocalizedError {
        let reason: String

        init(_ reason: String) {
            self.reason = reason
        }

        var errorDescription: String? { reason }
    }
}
