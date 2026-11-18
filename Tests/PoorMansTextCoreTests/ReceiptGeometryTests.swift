#if os(macOS)
import AppKit
import PDFKit
import XCTest
@testable import PoorMansTextCore

final class ReceiptGeometryTests: XCTestCase {
    @MainActor
    func testLeftColumnRemainsLocalAtThreeZoomsAndFourRotations() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let leftColumn = CGRect(x: 85, y: 570, width: 150, height: 88)
        for rotation in [0, 90, 180, 270] {
            for userUnit in [1, 2] {
                let source = directory.appendingPathComponent("columns-\(rotation)-\(userUnit).pdf")
                let bytes = fixture(rotation: rotation, userUnit: userUnit)
                try bytes.write(to: source)
                let pdf = try ReceiptPDF.open(at: source)
                let page = try XCTUnwrap(pdf.page(at: 0))
                let document = try ReceiptPDF.read(pdf)
                XCTAssertEqual(document.pages.count, 2)
                XCTAssertTrue(document.pages[1].words.isEmpty)
                let first = document.pages[0]
                let scale = 72 / (25.4 * Double(userUnit))
                XCTAssertEqual(first.pointsPerMillimeter, scale, accuracy: 1e-9)
                XCTAssertEqual(first.words.map(\.text), ["LEFT", "ALPHA", "RIGHT", "OMEGA", "LEFT", "BRAVO", "RIGHT", "DELTA"])
                XCTAssertEqual(first.words[0].line, first.words[1].line)
                XCTAssertNotEqual(first.words[1].line, first.words[2].line)
                XCTAssertEqual(first.words[0].rectangle.x * scale, 100, accuracy: 1e-7)

                let view = PDFView(frame: CGRect(x: 0, y: 0, width: 540, height: 470))
                view.displayMode = .singlePageContinuous
                view.displayBox = .cropBox
                view.autoScales = false
                view.minScaleFactor = 0.1
                view.maxScaleFactor = 4
                view.document = pdf
                for zoom in [0.75, 1.5, 2] {
                    view.scaleFactor = zoom
                    view.layoutSubtreeIfNeeded()
                    let screen = view.convert(leftColumn, from: page)
                    let roundTrip = view.convert(screen, to: page)
                    XCTAssertEqual(roundTrip.minX, leftColumn.minX, accuracy: 1e-7)
                    XCTAssertEqual(roundTrip.minY, leftColumn.minY, accuracy: 1e-7)
                    XCTAssertEqual(roundTrip.width, leftColumn.width, accuracy: 1e-7)
                    XCTAssertEqual(roundTrip.height, leftColumn.height, accuracy: 1e-7)
                    let physical = roundTrip.applying(.init(scaleX: 1 / scale, y: 1 / scale))
                    let field = ReceiptField(name: "Column", rule: .region(page: 0, rectangle: ReceiptRectangle(physical)))
                    let mask = ReceiptMask(partner: "Fixture", documentType: "Columns", fields: [field])
                    let value = try XCTUnwrap(ReceiptExtractor.evaluate(mask, in: document).fields.first)
                    XCTAssertEqual(value.status, .confirmed)
                    XCTAssertEqual(value.value, "LEFT ALPHA\nLEFT BRAVO")
                    XCTAssertEqual(value.sources.map(\.text), ["LEFT", "ALPHA", "LEFT", "BRAVO"])
                    XCTAssertEqual(page.selection(for: roundTrip)?.selectionsByLine().compactMap(\.string),
                                   ["LEFT ALPHA", "LEFT BRAVO"])
                }
                let canvas = try XCTUnwrap(view.documentView)
                let scroll = try XCTUnwrap(canvas.enclosingScrollView)
                let screenBeforeScroll = view.convert(leftColumn, from: page)
                let local = canvas.convert(screenBeforeScroll, from: view)
                scroll.contentView.scroll(to: CGPoint(x: local.minX - 10, y: local.minY - 10))
                scroll.reflectScrolledClipView(scroll.contentView)
                let scrolled = view.convert(leftColumn, from: page)
                XCTAssertNotEqual(scrolled.origin, screenBeforeScroll.origin)
                XCTAssertTrue(view.bounds.contains(scrolled))
                XCTAssertEqual(view.convert(scrolled, to: page).minX, leftColumn.minX, accuracy: 1e-7)
                let crop = page.bounds(for: .cropBox)
                let outside = view.convert(crop.insetBy(dx: -50, dy: -50), from: page)
                let clipped = crop.intersection(view.convert(outside, to: page))
                XCTAssertEqual(clipped.minX, crop.minX, accuracy: 1e-7)
                XCTAssertEqual(clipped.minY, crop.minY, accuracy: 1e-7)
                XCTAssertEqual(clipped.width, crop.width, accuracy: 1e-7)
                XCTAssertEqual(clipped.height, crop.height, accuracy: 1e-7)
                XCTAssertEqual(try Data(contentsOf: source), bytes)
            }
        }
    }

    func testMalformedScaleAndPDFWithoutEmbeddedTextAreReported() throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("geometry.pdf")
        try fixture(userUnit: 0).write(to: source)
        XCTAssertThrowsError(try ReceiptPDF.read(ReceiptPDF.open(at: source))) { error in
            XCTAssertTrue(error.localizedDescription.contains("unusable text coordinates"))
        }
        try fixture(text: "").write(to: source)
        XCTAssertThrowsError(try ReceiptPDF.read(ReceiptPDF.open(at: source))) { error in
            XCTAssertTrue(error.localizedDescription.contains("embedded text"))
        }
        try fixture(cropLeft: 166).write(to: source)
        XCTAssertThrowsError(try ReceiptPDF.read(ReceiptPDF.open(at: source))) { error in
            XCTAssertTrue(error.localizedDescription.contains("crop boundary"))
        }
    }

    private func testDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func fixture(rotation: Int = 0, userUnit: Int = 1, cropLeft: Int = 50, text: String = """
        BT /F1 18 Tf
        1 0 0 1 100 630 Tm (LEFT ALPHA) Tj 1 0 0 1 350 630 Tm (RIGHT OMEGA) Tj
        1 0 0 1 100 595 Tm (LEFT BRAVO) Tj 1 0 0 1 350 595 Tm (RIGHT DELTA) Tj
        1 0 0 1 25 685 Tm (HIDDEN) Tj ET
        """) -> Data {
        // Core Graphics schreibt die hier eigens geprüften /Rotate- und /UserUnit-Einträge nicht.
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 610 720] /CropBox [\(cropLeft) 70 570 670] /Rotate \(rotation) /UserUnit \(userUnit) /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let xref = data.count
        let entries = offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        data.append(contentsOf: """
            xref
            0 \(objects.count + 1)
            0000000000 65535 f
            \(entries)trailer
            << /Size \(objects.count + 1) /Root 1 0 R >>
            startxref
            \(xref)
            %%EOF

            """.utf8)
        return data
    }
}
#endif
