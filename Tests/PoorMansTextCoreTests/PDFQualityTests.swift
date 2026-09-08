import Foundation
import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import PoorMansTextCore

final class PDFQualityTests: XCTestCase {
    func testRealMixedColumnsAndMarginsPreserveSourceContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, in context: CGContext) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: y)
    context.setFillColor(gray: 0, alpha: 1)
    CTLineDraw(CTLineCreateWithAttributedString(attr), context)
}
func pdf(_ name: String, pages: Int = 1, body: (CGContext, Int) -> Void) {
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let url = root.appendingPathComponent(name)
    precondition(!FileManager.default.fileExists(atPath: url.path))
    let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
    for page in 0..<pages {
        context.beginPDFPage(nil)
        body(context, page)
        context.endPDFPage()
    }
    context.closePDF()
}
let paragraphs = [
    "Scanned paragraph alpha contains forty two apples.",
    "Scanned paragraph beta describes seven green trees.",
    "Scanned paragraph gamma preserves every written word.",
    "Scanned paragraph delta mentions a quiet blue river.",
    "Scanned paragraph epsilon describes the local library.",
    "Scanned paragraph zeta records the complete document."
]
let imageContext = CGContext(data: nil, width: 1500, height: 1700, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
imageContext.setFillColor(gray: 1, alpha: 1)
imageContext.fill(CGRect(x: 0, y: 0, width: 1500, height: 1700))
for (index, text) in paragraphs.enumerated() { line(text, 60, CGFloat(1530 - index * 210), 43, in: imageContext) }
let scan = imageContext.makeImage()!
pdf("mixed.pdf") { context, _ in
    line("Digital document header with enough text to pass the old threshold", 30, 754, 13, in: context)
    context.draw(scan, in: CGRect(x: 35, y: 60, width: 542, height: 650))
}
pdf("columns.pdf") { context, _ in
    line("Two column reading order", 40, 750, 20, in: context)
    for i in 0..<8 {
        line("LEFT \(i + 1) alpha beta gamma", 40, CGFloat(690 - i * 55), 13, in: context)
        line("RIGHT \(i + 1) delta epsilon", 330, CGFloat(690 - i * 55), 13, in: context)
    }
}
pdf("margins.pdf", pages: 3) { context, page in
    line("REPEATED HEADER", 40, 760, 14, in: context)
    line("REPEATED FOOTER", 40, 20, 12, in: context)
    line("Body content page \(page + 1) stays in the document.", 40, 600, 14, in: context)
    if page == 1 { line("REPEATED HEADER", 40, 400, 14, in: context) }
    line("Every paragraph remains available for comparison.", 40, 220, 14, in: context)
}

        func convert(_ name: String, _ options: ConversionOptions) throws -> (String, ConversionResult) {
            let source = root.appendingPathComponent(name + ".pdf")
            let before = try Data(contentsOf: source)
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(root.appendingPathComponent(UUID().uuidString)), options: options))
            XCTAssertEqual(try Data(contentsOf: source), before)
            return (try String(contentsOf: result.markdownFile, encoding: .utf8), result)
        }
        let (mixed, mixedResult) = try convert("mixed", ConversionOptions(ocrLanguages: ["en"]))
        for paragraph in paragraphs { XCTAssertTrue(mixed.contains(paragraph), mixed) }
        XCTAssertTrue(mixed.contains("Digital document header with enough text to pass the old threshold"), mixed)
        XCTAssertTrue(mixedResult.diagnostics.contains { $0.code == "pdf.ocrApplied" })
        let (off, offResult) = try convert("mixed", ConversionOptions(pdfTextRecognition: .disabled))
        XCTAssertFalse(off.contains(paragraphs[0]))
        XCTAssertFalse(offResult.diagnostics.contains { $0.code == "pdf.ocrApplied" })
        XCTAssertTrue(off.contains("Digital document header with enough text to pass the old threshold"))
        let (columns, _) = try convert("columns", ConversionOptions(pdfTextRecognition: .disabled))
        for index in 1...8 {
            XCTAssertEqual(columns.components(separatedBy: "LEFT \(index) alpha beta gamma").count, 2, columns)
            XCTAssertEqual(columns.components(separatedBy: "RIGHT \(index) delta epsilon").count, 2, columns)
        }
        XCTAssertLessThan(try XCTUnwrap(columns.range(of: "LEFT 8")).lowerBound, try XCTUnwrap(columns.range(of: "RIGHT 1")).lowerBound)
        let (margins, result) = try convert("margins", ConversionOptions(pdfTextRecognition: .disabled, pdfRemoveHeadersFooters: true))
        XCTAssertEqual(margins.components(separatedBy: "REPEATED HEADER").count, 2, margins)
        XCTAssertFalse(margins.contains("REPEATED FOOTER"), margins)
        XCTAssertEqual(result.diagnostics.filter { $0.code == "pdf.repeatedMarginRemoved" }.compactMap { $0.location?.page }, [1, 2, 3])
        let (legacy, _) = try convert("columns", ConversionOptions(pdfTextRecognition: .disabled, pdfLayout: .legacy))
        XCTAssertLessThan(try XCTUnwrap(legacy.range(of: "RIGHT 1")).lowerBound, try XCTUnwrap(legacy.range(of: "LEFT 8")).lowerBound)
        let (_, always) = try convert("columns", ConversionOptions(pdfTextRecognition: .always, ocrLanguages: ["en"]))
        XCTAssertTrue(always.diagnostics.contains { $0.code == "pdf.ocrApplied" })
    }

    func testInheritedPageResourcesDetectScanCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for inherited in [false, true] {
            let resources = "/Resources << /Font << /F1 4 0 R >> /XObject << /Im1 6 0 R >> >>"
            let content = "BT /F1 12 Tf 20 750 Td (Digital header with more than twenty characters) Tj ET q 256 0 0 128 20 300 cm /Im1 Do Q"
            let pixels = String(repeating: "A", count: 256 * 128)
            let objects = [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 \(inherited ? resources : "") >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R \(inherited ? "" : resources) >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
                "<< /Type /XObject /Subtype /Image /Width 256 /Height 128 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length \(pixels.utf8.count) >>\nstream\n\(pixels)\nendstream"
            ]
            var pdf = "%PDF-1.4\n", offsets = [0]
            for (index, object) in objects.enumerated() {
                offsets.append(pdf.utf8.count)
                pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
            }
            let xref = pdf.utf8.count
            pdf += "xref\n0 7\n0000000000 65535 f \n"
            for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
            pdf += "trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
            let source = root.appendingPathComponent("\(inherited).pdf")
            let bytes = Data(pdf.utf8)
            try bytes.write(to: source)
            let document = try XCTUnwrap(PDFDocument(url: source))
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertTrue((page.string ?? "").contains("Digital header with more than twenty characters"))
            XCTAssertTrue(PDFImageResources.containsScanCandidate(on: page), "inherited=\(inherited)")
            let result = try DocumentConverter().convert(ConversionRequest(inputURL: source, options: ConversionOptions(ocrLanguages: ["en"])))
            XCTAssertTrue(result.diagnostics.contains { $0.code == "pdf.ocrApplied" })
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testLanguageValidationAndLegacyWarningDecoding() throws {
        XCTAssertEqual(try OCRLanguageSelection.resolve(["de", "en", "DE"]), ["de-DE", "en-US"])
        XCTAssertThrowsError(try OCRLanguageSelection.resolve(["not-a-language"]))
        XCTAssertThrowsError(try OCRLanguageSelection.resolve([""]))
        XCTAssertNil(try JSONDecoder().decode(ConversionWarning.self, from: Data(#"{"code":"old","message":"Still works"}"#.utf8)).location)
        let warning = ConversionWarning(code: "x", message: "y", location: ConversionLocation(page: 2, sheet: "Sheet", cell: "B7"))
        XCTAssertEqual(try JSONDecoder().decode(ConversionWarning.self, from: JSONEncoder().encode(warning)), warning)
    }

    func testRotatedGeometryRetainsTheCompleteOriginalText() throws {
        let document = PDFDocument()
        // Reuse a genuine PDF page generated by a bitmap-free CGContext.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Rotated text retains every original word.", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), context)
        context.endPDFPage()
        context.closePDF()
        let page = try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
        document.insert(page, at: 0)
        page.rotation = 90
        let lines = try PDFTextLayout.lines(on: page)
        XCTAssertEqual(lines.map(\.text).joined(), page.string)
        XCTAssertEqual(lines.count, 1)
    }

    func testConservativeHyphens() {
        XCTAssertEqual(PDFTextLayout.cleanedHyphenation("soft\u{00AD}\nware", hardHyphens: false), "software")
        XCTAssertEqual(PDFTextLayout.cleanedHyphenation("import-\nant", hardHyphens: false), "import-\nant")
        XCTAssertEqual(PDFTextLayout.cleanedHyphenation("import-\nant", hardHyphens: true), "important")
        XCTAssertEqual(PDFTextLayout.cleanedHyphenation("well-\nKnown", hardHyphens: true), "well-\nKnown")
    }
}
