#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import PoorMansTextCore

final class ReceiptBatchTests: XCTestCase {
    func testSavedMaskHandlesShiftAmbiguityCollisionsAndDamagedPDF() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = try directory(in: root, name: "Left")
        let right = try directory(in: root, name: "Right")
        let output = try directory(in: root, name: "Results")
        let example = root.appendingPathComponent("A.pdf")
        let shifted = root.appendingPathComponent("B.pdf")
        let ambiguous = root.appendingPathComponent("C.pdf")
        let damaged = root.appendingPathComponent("damaged.pdf")
        let occupied = root.appendingPathComponent("occupied.pdf")
        let duplicateA = left.appendingPathComponent("same.pdf")
        let duplicateB = right.appendingPathComponent("same.pdf")
        try fixture(example, identifier: "NW-4711", date: "2026-10-01")
        try fixture(shifted, identifier: "NW-5802", date: "2026-10-11", offset: 9)
        try fixture(ambiguous, identifier: "NW-5984", date: "2026-10-13", secondDate: "2026-10-16")
        try Data("Invalid PDF".utf8).write(to: damaged)
        for copy in [occupied, duplicateA, duplicateB] { try FileManager.default.copyItem(at: example, to: copy) }
        let occupiedOutput = output.appendingPathComponent("occupied.pdf.json")
        let sentinel = Data("Existing file".utf8)
        try sentinel.write(to: occupiedOutput)
        let originalBytes = try Data(contentsOf: shifted)

        let document = try ReceiptPDF.read(ReceiptPDF.open(at: example))
        let fields = ReceiptExtractor.suggestions(in: document)
        XCTAssertEqual(fields.map(\.name), ["Invoice number", "Invoice date"])
        let mask = ReceiptMask(partner: "Northwood Paper", documentType: "Invoice", fields: fields)
        let maskURL = root.appendingPathComponent("northwood-invoice.json")
        try mask.save(to: maskURL)
        let reloaded = try ReceiptMask.load(from: maskURL)
        XCTAssertEqual(reloaded, mask)
        XCTAssertThrowsError(try mask.save(to: maskURL))

        var preview = ReceiptExtractor.evaluate(reloaded, in: document)
        XCTAssertEqual(preview.fields.map(\.value), ["NW-4711", "2026-10-01"])
        preview.correct(field: try XCTUnwrap(fields.first?.id), value: "NW-4711-C")
        XCTAssertEqual(preview.fields.first?.status, .corrected)
        XCTAssertEqual(try ReceiptMask.load(from: maskURL), reloaded)

        let inputs = [damaged, shifted, ambiguous, occupied, duplicateA, duplicateB]
        let beside = try ReceiptBatch.run(inputs: [shifted, ambiguous, duplicateA, duplicateB], mask: reloaded)
        XCTAssertEqual(beside.items.map(\.status), [.success, .reviewRequired, .success, .success])
        let besideB = root.appendingPathComponent("B.pdf.json")
        let besideC = root.appendingPathComponent("C.pdf.json")
        try assertJSON(besideB, identifier: "NW-5802", date: "2026-10-11", candidates: ["2026-10-11"])
        try assertJSON(besideC, identifier: "NW-5984", date: nil, candidates: ["2026-10-13", "2026-10-16"])

        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("poormans-text")
        let run = try ProcessRunner.run(
            executable: executable,
            arguments: ["extract", "--mask", maskURL.path, "--output-dir", output.path, "--format", "json"]
                + inputs.map(\.path),
            currentDirectory: root,
            captureStandardOutput: true,
            timeout: 30
        )
        XCTAssertEqual(run.status, 1, run.standardError)
        XCTAssertTrue(run.standardError.contains("[6/6]"))
        let cli = try JSONDecoder().decode(ReceiptBatchSummary.self, from: Data(run.standardOutput.utf8))
        XCTAssertEqual(cli.items.map(\.source), inputs.map(\.path))
        XCTAssertEqual(cli.items.map(\.status), [.failed, .success, .reviewRequired, .failed, .failed, .failed])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("B.pdf.json")), try Data(contentsOf: besideB))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("C.pdf.json")), try Data(contentsOf: besideC))
        XCTAssertEqual(try Data(contentsOf: occupiedOutput), sentinel)
        XCTAssertEqual(try Data(contentsOf: shifted), originalBytes)
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: output.path)),
                       ["occupied.pdf.json", "B.pdf.json", "C.pdf.json"])
    }

    func testCancellationPreservesCompletedFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.pdf")
        let second = root.appendingPathComponent("second.pdf")
        try fixture(first, identifier: "NW-12", date: "2026-11-08")
        try fixture(second, identifier: "NW-13", date: "2026-11-09")
        let fields = ReceiptExtractor.suggestions(in: try ReceiptPDF.read(ReceiptPDF.open(at: first)))
        let mask = ReceiptMask(partner: "Northwood Paper", documentType: "Invoice", fields: fields)
        let cancellation = ConversionCancellationToken()
        let summary = try ReceiptBatch.run(inputs: [first, second], mask: mask, cancellation: cancellation) {
            completed, _, _ in
            if completed == 1 { cancellation.cancel() }
        }
        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.items.map(\.status), [.success, .cancelled])
        try assertJSON(ReceiptBatch.destination(for: first), identifier: "NW-12",
                       date: "2026-11-08", candidates: ["2026-11-08"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ReceiptBatch.destination(for: second).path))
    }

    private func assertJSON(
        _ url: URL, identifier: String, date: String?, candidates: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["Invoice number"] as? String, identifier, file: file, line: line)
        if let date {
            XCTAssertEqual(data["Invoice date"] as? String, date, file: file, line: line)
        } else {
            XCTAssertTrue(data["Invoice date"] is NSNull, file: file, line: line)
        }
        let sources = try XCTUnwrap(json["sources"] as? [String: [[String: Any]]])
        XCTAssertEqual(sources["Invoice date"]?.compactMap { $0["text"] as? String }, candidates, file: file, line: line)
        XCTAssertTrue(sources["Invoice date"]?.allSatisfy { $0["page"] as? Int == 0
            && $0["origin"] as? String == "embeddedText" } == true, file: file, line: line)
        let review = try XCTUnwrap(json["review"] as? [String: [String: String]])
        XCTAssertEqual(review["Invoice date"]?["status"], date == nil ? "ambiguous" : "confirmed", file: file, line: line)
    }

    private func directory(in parent: URL = FileManager.default.temporaryDirectory, name: String = UUID().uuidString) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func fixture(_ url: URL, identifier: String, date: String, offset: CGFloat = 0, secondDate: String? = nil) throws {
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        context.beginPDFPage(nil)
        func draw(_ text: String, _ x: CGFloat, _ y: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [fontKey: font]))
            context.textPosition = CGPoint(x: x + offset, y: y - offset)
            CTLineDraw(line, context)
        }
        draw("Northwood Paper", 50, 780)
        draw("Invoice number:", 50, 730)
        draw(identifier, 180, 730)
        draw("Invoice date:", 50, 697)
        draw(date, 180, 697)
        if let secondDate { draw(secondDate, 275, 697) }
        context.endPDFPage()
        context.closePDF()
    }
}
#endif
