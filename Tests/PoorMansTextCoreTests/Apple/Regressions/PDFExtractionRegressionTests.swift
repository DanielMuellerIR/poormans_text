import AppKit
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import PoorMansTextCore

final class PDFExtractionRegressionTests: XCTestCase {
    func testRotatedGlyphOrderAndFallbackOCRKeepEachSentenceOnce() throws {
        let root = try makeRegressionDirectory()
        let source = root.appendingPathComponent("rotated-text.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(gray: 1, alpha: 1); context.fill(box)
        context.setFillColor(gray: 0, alpha: 1)
        context.translateBy(x: 570, y: 700); context.rotate(by: .pi)
        for (index, text) in ["Alpha sentence with twelve apples.", "Beta sentence with seven trees."].enumerated() {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 20, y: CGFloat(index * 55))
            let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), context)
        }
        context.endPDFPage(); context.closePDF()
        let before = try Data(contentsOf: source)
        let page = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0))
        XCTAssertEqual(page.rotation, 0)
        let reference = try XCTUnwrap(page.string)
        XCTAssertEqual(try PDFTextLayout.lines(on: page).map(\.text).joined(separator: "\n"), reference)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
            options: ConversionOptions(pdfTextRecognition: .always, ocrLanguages: ["en"])))
        let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
        for sentence in ["Alpha sentence with twelve apples.", "Beta sentence with seven trees."] {
            XCTAssertEqual(output.components(separatedBy: sentence).count - 1, 1, output)
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testFallbackOCRRetainsAnEqualSentenceAtAnotherPosition() throws {
        let root = try makeRegressionDirectory()
        let sentence = "Repeated sentence with twelve apples."
        func draw(_ context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat) {
            context.textMatrix = .identity; context.textPosition = CGPoint(x: x, y: y)
            context.setFillColor(gray: 0, alpha: 1)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: sentence, attributes:
                [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil)])), context)
        }
        let raster = try XCTUnwrap(CGContext(data: nil, width: 1500, height: 180,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        raster.setFillColor(gray: 1, alpha: 1); raster.fill(CGRect(x: 0, y: 0, width: 1500, height: 180))
        draw(raster, x: 30, y: 70, size: 65)
        let image = try XCTUnwrap(raster.makeImage())
        let source = root.appendingPathComponent("repeat-fallback.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        draw(context, x: 30, y: 650, size: 24)
        context.draw(image, in: CGRect(x: 30, y: 200, width: 550, height: 66))
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        XCTAssertTrue(document.write(to: source))
        let before = try Data(contentsOf: source)
        let result = try DocumentConverter().convert(ConversionRequest(inputURL: source,
            options: ConversionOptions(pdfTextRecognition: .always, ocrLanguages: ["en"])))
        let output = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(output.components(separatedBy: sentence).count - 1, 2, output)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "pdf.layoutFallback" })
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testLiteralPDFRectanglesAndLineOrderProduceSameCompleteGrid() throws {
        let ascending = [400,420,440,460].map { "40 \($0) m 240 \($0) l S" }.joined(separator: "\n")
        let descending = [460,440,420,400].map { "40 \($0) m 240 \($0) l S" }.joined(separator: "\n")
        let vertical = [40,140,240].map { "\($0) 400 m \($0) 460 l S" }.joined(separator: "\n")
        let rectangles = [400,420,440].flatMap { y in [40,140].map { x in "\(x) \(y) 100 20 re S" }}.joined(separator: "\n")
        for content in [ascending + "\n" + vertical, descending + "\n" + vertical, rectangles] {
            let page = try XCTUnwrap(PDFDocument(data: pdf(content))?.page(at: 0))
            let grids = PDFTableGeometry.grids(on: page, textHeight: 12)
            XCTAssertEqual(grids.count, 1)
            XCTAssertEqual(grids.first?.rows.count, 4)
            XCTAssertEqual(grids.first?.columns.count, 3)
        }
    }

    private func pdf(_ content: String) -> Data {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>", "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"]
        var output = "%PDF-1.4\n", offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(output.utf8.count)
            output += "\(index+1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = output.utf8.count
        output += "xref\n0 5\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { output += String(format: "%010d 00000 n \n", offset) }
        output += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(output.utf8)
    }
}
