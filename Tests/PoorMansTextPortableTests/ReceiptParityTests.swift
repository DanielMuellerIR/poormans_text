import Foundation
import XCTest
@testable import PoorMansTextCore

final class ReceiptParityTests: XCTestCase {
    func testMaskRejectsUnsupportedPagesAndDoesNotPublishOversizedJSON() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("mask.json")
        let rectangle = ReceiptRectangle(x: 1, y: 1, width: 2, height: 2)
        for page in [999, 1_000, Int.max] {
            let mask = ReceiptMask(partner: "Partner", documentType: "Invoice", fields: [
                ReceiptField(name: "Field", rule: .region(page: page, rectangle: rectangle)),
            ])
            if page == 999 {
                try mask.save(to: output)
                XCTAssertEqual(try ReceiptMask.load(from: output), mask)
                try FileManager.default.removeItem(at: output)
            } else {
                XCTAssertThrowsError(try mask.save(to: output))
                try JSONEncoder().encode(mask).write(to: output)
                XCTAssertThrowsError(try ReceiptMask.load(from: output))
                try FileManager.default.removeItem(at: output)
            }
        }

        let quote = String(repeating: "\"", count: 512)
        let fields = (0..<500).map { index in
            ReceiptField(name: String(quote.prefix(509)) + "\(index)", rule: .rightOf(label: quote, kind: .identifier))
        }
        let oversized = ReceiptMask(partner: "Partner", documentType: "Invoice", fields: fields)
        XCTAssertThrowsError(try oversized.save(to: output)) { error in
            XCTAssertTrue(error.localizedDescription.contains("1 MB"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testPreparedEvaluationKeepsRepeatedAnchorsOnTheirRowsAndBoundsEvidence() throws {
        let rows = (0..<1_000).flatMap { index -> [ReceiptWord] in
            let y = Double(1_000 - index) * 5
            return [ReceiptWord(text: "Number:", rectangle: .init(x: 0, y: y, width: 14, height: 3), line: index),
                    ReceiptWord(text: "N-\(index)", rectangle: .init(x: 30, y: y, width: 16, height: 3), line: index + 1_000)]
        }
        let document = ReceiptDocument(pages: [ReceiptPage(pointsPerMillimeter: 1, words: rows)])
        let prepared = try ReceiptExtractor.Prepared(document)
        let rule = ReceiptRule.rightOf(label: "Number", kind: .identifier)
        let value = try XCTUnwrap(prepared.evaluate(ReceiptMask(fields: [.init(name: "Number", rule: rule)])).fields.first)
        XCTAssertEqual(value.status, .ambiguous)
        XCTAssertEqual(value.sources.map(\.text), (0..<1_000).map { "N-\($0)" })

        let overlapping = ReceiptMask(fields: (0..<16).map { index in
            ReceiptField(name: "Field \(index)", rule: .region(page: 0, rectangle: .init(x: 0, y: 0, width: 50, height: 5_010)))
        })
        XCTAssertThrowsError(try prepared.evaluate(overlapping)) { error in
            XCTAssertTrue(error.localizedDescription.contains("evidence limit"))
        }
    }

    func testSharedMaskExtractsTheSameFieldsFromRotatedAndScaledRealPDFs() throws {
        try requireReceiptBackend()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = try [0, 90, 180, 270].enumerated().map { index, rotation in
            try makePDF(in: directory, name: "receipt-\(rotation)", rotation: rotation, unit: index.isMultiple(of: 2) ? 1 : 2)
        }
        let blank = try makePDF(in: directory, name: "scan", drawsText: false)
        let damaged = directory.appendingPathComponent("damaged.pdf")
        try Data("%PDF-1.7\nInvalid.".utf8).write(to: damaged)
        let occupied = directory.appendingPathComponent("occupied.pdf")
        try FileManager.default.copyItem(at: documents[0], to: occupied)
        let sentinel = Data("Existing result".utf8)
        try sentinel.write(to: ReceiptBatch.destination(for: occupied))
        let expectedBytes = try documents.map { try Data(contentsOf: $0) }

        let url = directory.appendingPathComponent("shared-mask.json")
        let mask = Self.mask()
        try mask.save(to: url)
        let inputs = documents + [blank, damaged, occupied]
        let summary = try ReceiptBatch.run(inputs: inputs, mask: ReceiptMask.load(from: url))
        XCTAssertEqual(summary.items.map(\.status), Array(repeating: .reviewRequired, count: documents.count)
                       + [.failed, .failed, .failed], summary.items.compactMap(\.diagnostic).joined(separator: "\n"))
        XCTAssertTrue(summary.items[4].diagnostic?.contains("embedded text") == true)
        XCTAssertTrue(summary.items[6].diagnostic?.contains("already in use") == true)
        XCTAssertEqual(try Data(contentsOf: ReceiptBatch.destination(for: occupied)), sentinel)
        XCTAssertEqual(try documents.map { try Data(contentsOf: $0) }, expectedBytes)

        for source in documents {
            let result = try object(Data(contentsOf: ReceiptBatch.destination(for: source)))
            let data = try XCTUnwrap(result["data"] as? [String: Any])
            let review = try XCTUnwrap(result["review"] as? [String: [String: String]])
            let sources = try XCTUnwrap(result["sources"] as? [String: [[String: Any]]])
            XCTAssertEqual(data["Column"] as? String, "LEFT ALPHA\nLEFT BRAVO")
            XCTAssertEqual(data["Number"] as? String, "NW-4711")
            XCTAssertTrue(data["Date"] is NSNull)
            XCTAssertTrue(data["Missing"] is NSNull)
            XCTAssertEqual(review.compactMapValues { $0["status"] }, ["Column": "confirmed", "Number": "confirmed",
                                                                      "Date": "ambiguous", "Missing": "missing"])
            XCTAssertEqual(sources["Date"]?.compactMap { $0["text"] as? String }, ["2026-10-13", "2026-10-16"])
            XCTAssertEqual(sources["Column"]?.compactMap { $0["text"] as? String }, ["LEFT", "ALPHA", "LEFT", "BRAVO"])
            let evidence = try XCTUnwrap(sources["Column"]?.first)
            XCTAssertEqual(evidence["page"] as? Int, 0)
            XCTAssertEqual(evidence["origin"] as? String, "embeddedText")
            let rect = try XCTUnwrap(evidence["rectangle"] as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(rect["x"]), 100 * 25.4 / 72, accuracy: 0.1)
        }
    }

    #if os(Linux)
    func testLinuxEditorUsesTheBoundSourceForSelectionsAndCorrections() throws {
        try requireReceiptBackend()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makePDF(in: directory, name: "rotated", rotation: 90, unit: 2)
        let requestFile = directory.appendingPathComponent("request.json")
        func request(_ message: [String: Any]) throws -> [String: Any] {
            try JSONSerialization.data(withJSONObject: message).write(to: requestFile)
            return try object(ReceiptEditorProtocol.run(requestFile: requestFile))
        }

        let mask = Self.mask()
        let maskObject = try object(JSONEncoder().encode(mask))
        let inspection = try request(["action": "inspect", "source": source.path, "page": 0, "mask": maskObject])
        let sourceIdentity = try XCTUnwrap(inspection["sourceIdentity"] as? [String: Any])
        let pages = try XCTUnwrap(inspection["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.first?["rotation"] as? Int, 90)
        let bounds = try XCTUnwrap(pages.first?["bounds"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(bounds["x"]), 50 * 25.4 / 72, accuracy: 0.1)
        let preview = try XCTUnwrap(inspection["preview"] as? [String: Any])
        XCTAssertEqual(preview["index"] as? Int, 1)
        XCTAssertEqual((preview["sourceIdentity"] as? [String: Any])?["sha256"] as? String,
                       (sourceIdentity["sha256"] as? String))
        XCTAssertEqual((inspection["suggestions"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
                       ["Invoice number", "Invoice date"])

        let evaluated = try request(["action": "evaluate", "source": source.path, "sourceIdentity": sourceIdentity,
                                     "mask": maskObject])
        let previewResult = try XCTUnwrap(inspection["result"] as? NSDictionary)
        XCTAssertEqual(previewResult, evaluated["result"] as? NSDictionary)
        XCTAssertEqual((previewResult["data"] as? [String: Any])?["Number"] as? String, "NW-4711")
        XCTAssertNil(evaluated["fields"])

        let pageRequest: [String: Any] = ["action": "previewPage", "source": source.path, "page": 1,
                                          "sourceIdentity": sourceIdentity]
        let secondPage = try request(pageRequest)
        XCTAssertEqual((secondPage["preview"] as? [String: Any])?["index"] as? Int, 2)
        XCTAssertEqual((secondPage["words"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(secondPage["wordsTruncated"] as? Bool, false)
        XCTAssertNil(secondPage["suggestions"])
        XCTAssertNil(secondPage["result"])

        let destination = directory.appendingPathComponent("corrected.json")
        let export: [String: Any] = ["action": "export", "source": source.path, "sourceIdentity": sourceIdentity,
                                     "path": destination.path, "mask": maskObject,
                                     "corrections": [mask.fields[2].id.uuidString: "2026-10-16"]]
        let exported = try request(export)
        let result = try object(Data(contentsOf: destination))
        XCTAssertEqual((result["data"] as? [String: Any])?["Date"] as? String, "2026-10-16")
        XCTAssertEqual((result["review"] as? [String: [String: String]])?["Date"]?["status"], "corrected")
        XCTAssertEqual(Set(exported.keys), ["ok", "version", "operation"])
        XCTAssertEqual((result["sources"] as? [String: [[String: Any]]])?["Date"]?.count, 2)
        XCTAssertThrowsError(try request(export))
        _ = try makePDF(in: directory, name: "rotated", rotation: 180)
        XCTAssertThrowsError(try request(pageRequest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("source has changed"))
        }
        let stale = directory.appendingPathComponent("stale.json")
        var afterChange = export
        afterChange["path"] = stale.path
        XCTAssertThrowsError(try request(afterChange)) { error in
            XCTAssertTrue(error.localizedDescription.contains("source has changed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }
    #endif

    private func requireReceiptBackend() throws {
        #if os(Linux)
        guard ExternalToolResolver().isAvailable(.pythonPoppler), FileManager.default.isExecutableFile(atPath: "/usr/bin/qpdf")
        else { throw XCTSkip("Local Poppler and qpdf are required for the receipt fixture") }
        #endif
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReceiptParity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private static func mask() -> ReceiptMask {
        let millimeters = 25.4 / 72
        return ReceiptMask(partner: "Northwood Paper", documentType: "Invoice", fields: [
            ReceiptField(name: "Column", rule: .region(page: 0, rectangle: ReceiptRectangle(
                x: 85 * millimeters, y: 570 * millimeters, width: 150 * millimeters, height: 88 * millimeters))),
            ReceiptField(name: "Number", rule: .rightOf(label: "Invoice number", kind: .identifier)),
            ReceiptField(name: "Date", rule: .rightOf(label: "Invoice date", kind: .date)),
            ReceiptField(name: "Missing", rule: .rightOf(label: "Delivery note date", kind: .date)),
        ])
    }

    private func makePDF(in directory: URL, name: String, rotation: Int = 0, unit: Int = 1, drawsText: Bool = true) throws -> URL {
        let scale = Double(unit)
        func dimensions(_ points: [Int]) -> String { points.map { String(Double($0) / scale) }.joined(separator: " ") }
        let rows = [(100, 630, "LEFT ALPHA"), (350, 630, "RIGHT OMEGA"), (100, 595, "LEFT BRAVO"),
                    (350, 595, "RIGHT DELTA"), (100, 540, "Invoice number:"), (250, 540, "NW-4711"),
                    (100, 500, "Invoice date:"), (250, 500, "2026-10-13"), (380, 500, "2026-10-16"),
                    (25, 685, "HIDDEN")]
        let content = drawsText ? "BT /F1 \(18 / scale) Tf\n" + rows.map { x, y, text in
            "1 0 0 1 \(dimensions([x, y])) Tm (\(text)) Tj"
        }.joined(separator: "\n") + "\nET" : ""
        let pdfObjects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /Rotate \(rotation) /MediaBox [\(dimensions([10, 20, 610, 720]))] >>",
            "<< /Type /Page /Parent 2 0 R /CropBox [\(dimensions([50, 70, 570, 670]))] /UserUnit \(unit) /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Page /Parent 2 0 R /Resources << >> >>",
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in pdfObjects.enumerated() {
            offsets.append(data.count)
            data.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let xref = data.count
        let entries = offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        data.append(contentsOf: "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n\(entries)".utf8)
        data.append(contentsOf: "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        let source = directory.appendingPathComponent(name + ".pdf")
        try data.write(to: source)
        return source
    }
}
