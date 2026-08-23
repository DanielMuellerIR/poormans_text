import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PoorMansTextCore

final class ImageAdapterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextImage-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testConvertsARealPNGWithOriginalAssetAndLocalOCR() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Readable sample.png")
        try createPNG(text: "Image OCR contract", at: sourceURL)
        let sourceBefore = try Data(contentsOf: sourceURL)

        let inspection = try DocumentConverter().inspect(sourceURL)
        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(inspection.format, .image)
        XCTAssertTrue(inspection.expectedWarnings.isEmpty)
        XCTAssertEqual(result.format, .image)
        XCTAssertEqual(result.assets.map(\.lastPathComponent), ["image01.png"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.assets.first)), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
        XCTAssertEqual(result.diagnostics.first?.code, "image.ocrApplied")
        XCTAssertTrue(markdown.contains("![Readable sample](images/image01.png)"), markdown)
        XCTAssertTrue(markdown.contains("## OCR text"), markdown)
        XCTAssertTrue(markdown.contains("Image OCR contract"), markdown)
    }

    func testImageOCROffKeepsOnlyTheOriginalAsset() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Only asset.png")
        try createPNG(text: "This text must not be read", at: sourceURL)
        let sourceBefore = try Data(contentsOf: sourceURL)

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("asset-result")),
                options: ConversionOptions(imageTextRecognition: .disabled)
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.assets.first)), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBefore)
        XCTAssertFalse(markdown.contains("## OCR text"), markdown)
        XCTAssertTrue(markdown.contains("![Only asset](images/image01.png)"), markdown)
    }

    func testDetectsImageContentWithoutAnImageFilenameExtension() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("camera-output.data")
        try createPNG(text: "Recognized by image data", at: sourceURL)

        XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), .image)
    }

    func testRejectsAFileNamedPNGWithoutImageData() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Invalid.png")
        try Data("not an image".utf8).write(to: sourceURL)

        XCTAssertThrowsError(try DocumentConverter().inspect(sourceURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("image format"), error.localizedDescription)
        }
    }

    func testKeepsMultiPageTIFFAsOneAssetAndMarksEveryTextlessFrame() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Two frames.tiff")
        try createTIFF(texts: ["", ""], at: sourceURL)
        let sourceBefore = try Data(contentsOf: sourceURL)

        let result = try DocumentConverter().convert(
            ConversionRequest(
                inputURL: sourceURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("tiff-result"))
            )
        )
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)

        XCTAssertEqual(result.assets.map(\.lastPathComponent), ["image01.tiff"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.assets.first)), sourceBefore)
        XCTAssertEqual(
            result.diagnostics.map(\.code),
            ["image.ocrApplied", "image.textUnavailable"]
        )
        XCTAssertTrue(markdown.contains("### Frame 1"), markdown)
        XCTAssertTrue(markdown.contains("### Frame 2"), markdown)
        XCTAssertEqual(
            markdown.components(separatedBy: "_No text could be extracted from this image frame._").count - 1,
            2,
            markdown
        )
    }

    func testRejectsAnImageThatExceedsTheOCRPixelBudgetBeforePublishing() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("Oversized.tiff")
        try createOversizedTIFF(at: sourceURL)
        let outputURL = temporaryDirectory.appendingPathComponent("oversized-result")

        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(inputURL: sourceURL, destination: .directory(outputURL))
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("OCR pixel budget"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private func createPNG(text: String, at url: URL) throws {
        guard let data = bitmap(text: text).representation(using: .png, properties: [:]) else {
            throw FixtureError("could not encode the PNG fixture")
        }
        try data.write(to: url, options: .atomic)
    }

    private func createTIFF(texts: [String], at url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.tiff.identifier as CFString,
            texts.count,
            nil
        ) else {
            throw FixtureError("could not create the TIFF destination")
        }
        for text in texts {
            guard let image = bitmap(text: text).cgImage else {
                throw FixtureError("could not create a TIFF frame")
            }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError("could not finish the TIFF fixture")
        }
    }

    /// Ein unkomprimiertes Schwarzweißbild wäre groß; für die Budgetprüfung
    /// genügt ImageIO aber ein leerer, sehr großer Frame mit seinen echten
    /// Metadaten. Der Adapter muss ihn ablehnen, bevor Pixel dekodiert werden.
    private func createOversizedTIFF(at url: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4_001,
            pixelsHigh: 4_000,
            bitsPerSample: 1,
            samplesPerPixel: 1,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceWhite,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = bitmap.representation(using: .tiff, properties: [:]) else {
            throw FixtureError("could not encode the oversized TIFF fixture")
        }
        try data.write(to: url, options: .atomic)
    }

    private func bitmap(text: String) -> NSBitmapImageRep {
        let width = 1_600
        let height = 900
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        if !text.isEmpty {
            NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 72, weight: .regular),
                    .foregroundColor: NSColor.black,
                ]
            ).draw(at: NSPoint(x: 100, y: 410))
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private struct FixtureError: LocalizedError {
        let reason: String

        init(_ reason: String) {
            self.reason = reason
        }

        var errorDescription: String? { reason }
    }
}
