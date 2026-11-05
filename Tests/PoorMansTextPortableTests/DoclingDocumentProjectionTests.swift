import Foundation
import XCTest

@testable import PoorMansTextCore

final class DoclingDocumentProjectionTests: XCTestCase {
    private func document() -> [String: Any] {
        let bounds: [String: Any] = [
            "l": 10, "t": 90, "r": 90, "b": 10, "coord_origin": "BOTTOMLEFT",
        ]
        return [
            "schema_name": "DoclingDocument", "version": "1.11.0",
            "body": [
                "self_ref": "#/body", "children": [["$ref": "#/texts/0"]], "label": "unspecified",
                "content_layer": "body",
            ],
            "furniture": [
                "self_ref": "#/furniture", "children": [], "label": "unspecified",
                "content_layer": "furniture",
            ],
            "groups": [], "pictures": [], "tables": [], "key_value_items": [], "form_items": [],
            "texts": [
                [
                    "self_ref": "#/texts/0", "parent": ["$ref": "#/body"], "children": [],
                    "label": "text",
                    "content_layer": "body",
                    "orig": "é🙂e\u{301}", "text": "é🙂e\u{301}",
                    "prov": [["page_no": 1, "bbox": bounds, "charspan": [0, 4]]],
                ]
            ],
            "pages": ["1": ["page_no": 1, "size": ["width": 100, "height": 100]]],
        ]
    }

    private func data(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
    }

    private func rejected(
        _ mutation: (inout [String: Any]) -> Void, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var source = document()
        mutation(&source)
        XCTAssertThrowsError(
            try DoclingDocumentProjection.parse(data(source)), file: file, line: line)
    }

    private func tableDocument() -> [String: Any] {
        var source = document()
        var body = source["body"] as! [String: Any]
        body["children"] = [["$ref": "#/texts/0"], ["$ref": "#/tables/0"]]
        source["body"] = body
        let bounds: [String: Any] = [
            "l": 10, "t": 90, "r": 90, "b": 10, "coord_origin": "BOTTOMLEFT",
        ]
        func cell(_ text: String, row: Int, column: Int, span: Int) -> [String: Any] {
            [
                "text": text, "bbox": bounds, "row_span": 1, "col_span": span,
                "start_row_offset_idx": row, "end_row_offset_idx": row + 1,
                "start_col_offset_idx": column, "end_col_offset_idx": column + span,
            ]
        }
        let cells = [
            cell("header", row: 0, column: 0, span: 2), cell("left", row: 1, column: 0, span: 1),
            cell("right", row: 1, column: 1, span: 1),
        ]
        source["tables"] = [
            [
                "self_ref": "#/tables/0", "parent": ["$ref": "#/body"], "children": [],
                "label": "table",
                "content_layer": "body",
                "prov": [["page_no": 1, "bbox": bounds, "charspan": [0, 0]]],
                "data": [
                    "num_rows": 2, "num_cols": 2, "table_cells": cells, "grid": [cells, cells],
                ],
            ]
        ]
        return source
    }

    func testSpanningCellIsProjectedOnceWithoutCountingGridAliases() throws {
        let projection = try DoclingDocumentProjection.parse(data(tableDocument()))
        let table = try XCTUnwrap(projection.recognition.documents.first?.tables.first)
        XCTAssertEqual(table.cells.map(\.text.text), ["header", "left", "right"])
        XCTAssertEqual(table.cells[0].columns, 0...1)
        XCTAssertEqual(projection.rawCellCount, 3)
        XCTAssertEqual(projection.items.filter { $0.text == "header" }.count, 1)
    }

    func testSeparateListMarkerCannotBeSilentlyDropped() throws {
        try rejected { source in
            var texts = source["texts"] as! [[String: Any]]
            texts[0]["marker"] = "1."
            texts[0]["label"] = "list_item"
            source["texts"] = texts
        }
    }

    func testMissingOverlappingAndEscapingTableCellsReject() throws {
        for failure in ["missing", "overlap", "outside"] {
            var source = tableDocument()
            var tables = source["tables"] as! [[String: Any]]
            var payload = tables[0]["data"] as! [String: Any]
            var cells = payload["table_cells"] as! [[String: Any]]
            if failure == "missing" { cells.removeLast() }
            if failure == "overlap" {
                cells[2]["start_col_offset_idx"] = 0
                cells[2]["end_col_offset_idx"] = 1
            }
            if failure == "outside" {
                var box = cells[0]["bbox"] as! [String: Any]
                box["l"] = 0
                cells[0]["bbox"] = box
            }
            payload["table_cells"] = cells
            tables[0]["data"] = payload
            source["tables"] = tables
            XCTAssertThrowsError(try DoclingDocumentProjection.parse(data(source)), failure)
        }
    }

    func testTableSlotBudgetAppliesAcrossTheDocument() throws {
        var source = tableDocument()
        var tables = source["tables"] as! [[String: Any]]
        var payload = tables[0]["data"] as! [String: Any]
        var cell = (payload["table_cells"] as! [[String: Any]])[0]
        cell["row_span"] = 3000
        cell["col_span"] = 1
        cell["start_row_offset_idx"] = 0
        cell["end_row_offset_idx"] = 3000
        cell["start_col_offset_idx"] = 0
        cell["end_col_offset_idx"] = 1
        payload["num_rows"] = 3000
        payload["num_cols"] = 1
        payload["table_cells"] = [cell]
        tables[0]["data"] = payload
        var second = tables[0]
        second["self_ref"] = "#/tables/1"
        source["tables"] = [tables[0], second]
        var body = source["body"] as! [String: Any]
        body["children"] = [["$ref": "#/texts/0"], ["$ref": "#/tables/0"], ["$ref": "#/tables/1"]]
        source["body"] = body
        XCTAssertThrowsError(try DoclingDocumentProjection.parse(data(source))) { error in
            XCTAssertEqual(
                (error as? DoclingDocumentProjection.Failure)?.reason, "aggregate table slot budget"
            )
        }
    }

    func testSchemaKeysDoNotAcceptCamelCaseAliases() throws {
        var source = document()
        source["schemaName"] = source.removeValue(forKey: "schema_name")
        XCTAssertThrowsError(try DoclingDocumentProjection.parse(data(source)))
    }

    func testOriginalUnicodeBytesAndGeometrySurvive() throws {
        let projected = try DoclingDocumentProjection.parse(data(document()))
        let paragraph = try XCTUnwrap(projected.recognition.documents.first?.paragraphs.first)
        XCTAssertEqual(Array(paragraph.text.utf8), Array("é🙂e\u{301}".utf8))
        XCTAssertEqual(paragraph.bounds, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        XCTAssertEqual(projected.items.count, 1)
        XCTAssertTrue(projected.pictureRefs.isEmpty)
    }

    func testScalarProvenanceDoesNotSplitEmojiOrCombiningSequence() throws {
        let fragments = try DoclingDocumentProjection.scalarFragments(
            original: "é🙂e\u{301}", alternate: "é🙂e\u{301}", spans: [[0, 1], [1, 2], [2, 4]])
        XCTAssertEqual(
            fragments.map { Array($0.utf8) }, ["é", "🙂", "e\u{301}"].map { Array($0.utf8) })
        XCTAssertThrowsError(
            try DoclingDocumentProjection.scalarFragments(
                original: "one two", alternate: "one two", spans: [[0, 3]]))
        XCTAssertThrowsError(
            try DoclingDocumentProjection.scalarFragments(
                original: "abcd", alternate: "abcd", spans: [[0, 3], [2, 4]]))
    }

    func testDuplicateKeysAreRejectedBeforeFoundationCollapsesThem() throws {
        let bytes = try data(document())
        let duplicate = Data("{\"version\":\"invalid\",".utf8) + bytes.dropFirst()
        XCTAssertThrowsError(try DoclingDocumentProjection.parse(duplicate))
    }

    func testUnknownJSONFieldsStillHaveDepthBudget() throws {
        let bytes = try data(document())
        let nested = String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)
        let deep = Data(("{\"future_field\":" + nested + ",").utf8) + bytes.dropFirst()
        XCTAssertThrowsError(try DoclingDocumentProjection.parse(deep))
    }

    func testSchemaPageAndByteBoundariesRejectUnsupportedInputs() throws {
        try rejected { $0["version"] = "1.12.0" }
        try rejected { $0["pages"] = [:] }
        try rejected { $0["form_items"] = [[:]] }
        XCTAssertThrowsError(
            try DoclingDocumentProjection.parse(Data(repeating: 32, count: 8 * 1024 * 1024 + 1)))
    }

    func testUnreachableDuplicateAndWrongParentReferencesReject() throws {
        try rejected { source in
            var body = source["body"] as! [String: Any]
            body["children"] = []
            source["body"] = body
        }
        try rejected { source in
            var body = source["body"] as! [String: Any]
            body["children"] = [["$ref": "#/texts/0"], ["$ref": "#/texts/0"]]
            source["body"] = body
        }
        try rejected { source in
            var texts = source["texts"] as! [[String: Any]]
            texts[0]["parent"] = ["$ref": "#/furniture"]
            source["texts"] = texts
        }
    }

    func testContainerTextCannotDisappearSilently() throws {
        try rejected { source in
            var body = source["body"] as! [String: Any]
            body["orig"] = "must not vanish"
            source["body"] = body
        }
    }

    func testNaturalRecognitionFixturesPreserveIndependentOriginalInventory() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("docs/linux-port/P11-DOCLING-EVIDENCE/documents")
        for filename in [
            "01030000000132.json", "01030000000132-render.json", "01030000000135.json",
            "structured.json",
        ] {
            let input = try Data(contentsOf: fixtures.appendingPathComponent(filename))
            let original = try XCTUnwrap(
                JSONSerialization.jsonObject(with: input) as? [String: Any])
            let texts = try XCTUnwrap(original["texts"] as? [[String: Any]])
            let tables = try XCTUnwrap(original["tables"] as? [[String: Any]])
            var authoritative = try texts.map { try XCTUnwrap($0["orig"] as? String) }
            var cells = 0
            for table in tables {
                let tableData = try XCTUnwrap(table["data"] as? [String: Any])
                let rawCells = try XCTUnwrap(tableData["table_cells"] as? [[String: Any]])
                cells += rawCells.count
                authoritative += try rawCells.map { try XCTUnwrap($0["text"] as? String) }
            }
            let projection = try DoclingDocumentProjection.parse(input)
            func tokens(_ strings: [String]) -> [Data: Int] {
                var result = [Data: Int]()
                for text in strings {
                    for token in text.split(whereSeparator: { $0.isWhitespace }) {
                        result[Data(token.utf8), default: 0] += 1
                    }
                }
                return result
            }
            XCTAssertEqual(tokens(projection.items.map(\.text)), tokens(authoritative), filename)
            XCTAssertEqual(projection.rawCellCount, cells, filename)
            XCTAssertEqual(
                projection.recognition.documents.flatMap(\.tables).flatMap(\.cells).count, cells,
                filename)
        }
    }
}
