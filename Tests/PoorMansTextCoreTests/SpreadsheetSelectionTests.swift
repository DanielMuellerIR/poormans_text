import Foundation
import XCTest
@testable import PoorMansTextCore

final class SpreadsheetSelectionTests: XCTestCase {
    func testRangeGrammarAndCodableKeepStrictCoordinates() throws {
        XCTAssertEqual(try SpreadsheetCellRange("b2:D8").description, "B2:D8")
        XCTAssertEqual(try SpreadsheetCellRange("XFD1000000").lastColumn, 16_384)
        for value in ["", "A0", "A01", "A-1", "A1:", ":A1", "B2:A3", "A3:B2", "XFE1", "A1000001", "$A$1", "Sheet!A1", "A١", "Ａ1", "ß1", "ı1", "ſ1", "A1:B2:C3", " A1"] {
            XCTAssertThrowsError(try SpreadsheetCellRange(value), value)
        }
        let selection = try SpreadsheetSelection(sheets: .indices(IndexSelection("3,1,1")), ranges: [SpreadsheetCellRange("B2:C4"), SpreadsheetCellRange("B2:C4")])
        XCTAssertEqual(selection.ranges.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(SpreadsheetSelection.self, from: JSONEncoder().encode(selection)), selection)
        XCTAssertThrowsError(try SpreadsheetSelection(sheets: .names([])))
        XCTAssertThrowsError(try SpreadsheetSelection(ranges: Array(repeating: SpreadsheetCellRange("A1"), count: 65)))
    }

    func testRangeUnionDoesNotDuplicateCellsOrExpandAcrossGaps() throws {
        let selection = try SpreadsheetSelection(ranges: [SpreadsheetCellRange("B2:C3"), SpreadsheetCellRange("C3:D4"), SpreadsheetCellRange("P20")])
        let regions = try selection.disjointRanges(rowCount: 20, columnCount: 16)
        var cells = Set<String>(), count = 0
        for region in regions {
            for row in region.firstRow...region.lastRow {
                for column in region.firstColumn...region.lastColumn { cells.insert("\(row):\(column)"); count += 1 }
            }
        }
        XCTAssertEqual(count, 8)
        XCTAssertEqual(cells.count, 8)
        XCTAssertFalse(cells.contains("10:10"))
    }

    func testSourceSheetIndicesVisibilityAndBoundedOverviewForAllFormats() throws {
        try withFixtures { root, sources in
            for source in sources {
                let bytes = try Data(contentsOf: source)
                let summary = try DocumentConverter().inspectSpreadsheetContents(source)
                XCTAssertEqual(summary.sheets.map(\.index), [1, 2, 3])
                XCTAssertEqual(summary.sheets.map(\.name), ["Visible", "Hidden", "VeryHidden"])
                XCTAssertEqual(summary.sheets.map(\.visibility), source.pathExtension == "ods" ? [.visible, .hidden, .hidden] : [.visible, .hidden, .veryHidden])
                XCTAssertTrue(try summary.sourceIdentity.matchesFile(at: source))
                XCTAssertEqual(try Data(contentsOf: source), bytes)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
        }
    }

    func testAllAndDefaultRemainByteEqualAndVisibleSelectsOnlyVisibleSheet() throws {
        try withFixtures { root, sources in
            for source in sources {
                let parsed = try read(source)
                XCTAssertEqual(parsed.sheets.count, 3)
                let selected = try parsed.selecting(SpreadsheetSelection(sheets: .visible))
                XCTAssertEqual(selected.sheets.map(\.name), ["Visible"])
                XCTAssertEqual(try parsed.selecting(SpreadsheetSelection(sheets: .all)).sheets.count, 3)
                let before = try SpreadsheetMarkdownRenderer.render(parsed, sourceURL: source, style: .markdownTable)
                XCTAssertTrue(before.contains("## Sheet: Hidden"))
                let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(source.lastPathComponent + "-default"))))
                XCTAssertEqual(try String(contentsOf: result.markdownFile, encoding: .utf8), before)
            }
        }
    }

    func testSelectedRangesPreserveSourceCoordinatesAndEveryMarkerInBothLayouts() throws {
        try withFixtures { root, sources in
            for source in sources {
                let original = try Data(contentsOf: source)
                for style in [SpreadsheetRendering.markdownTable, .tabSeparated] {
                    for layout in [OutputLayout.markdownFolder, .textbundle] {
                        let selection = try SpreadsheetSelection(sheets: .indices(IndexSelection("3,1,1")), ranges: [SpreadsheetCellRange("D2:E3"), SpreadsheetCellRange("E3:E4")])
                        let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(root.appendingPathComponent(UUID().uuidString + (layout == .textbundle ? ".textbundle" : ""))), options: .init(spreadsheetRendering: style, outputLayout: layout, spreadsheetSelection: selection, conversionReport: true)))
                        let data = try Data(contentsOf: result.markdownFile), text = String(decoding: data, as: UTF8.self)
                        XCTAssertFalse(text.contains("## Sheet: Hidden"))
                        XCTAssertEqual(result.sourceMappings.count, 10)
                        for sheet in [1, 3] {
                            for (row, column) in [(2, 4), (2, 5), (3, 4), (3, 5), (4, 5)] {
                                let marker = String(sheet * 1000 + row * 100 + column)
                                XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, text)
                                let mapping = try XCTUnwrap(result.sourceMappings.first { $0.source.sheetIndex == sheet && $0.source.cell == SpreadsheetCellRange.columnName(column) + String(row) })
                                XCTAssertEqual(mapping.output.text(in: data), marker)
                            }
                        }
                        let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
                        XCTAssertEqual(report.options.spreadsheetSelection, selection)
                        XCTAssertTrue(try report.source.matchesFile(at: source))
                    }
                }
                XCTAssertEqual(try Data(contentsOf: source), original)
            }
        }
    }

    func testNamesAreExactAndDuplicateSourceNamesRequireIndices() throws {
        let workbook = SpreadsheetWorkbook(sheets: [sheet("Same"), sheet("Same"), sheet("Other")])
        XCTAssertThrowsError(try workbook.selecting(SpreadsheetSelection(sheets: .names(["Same"]))))
        XCTAssertThrowsError(try workbook.selecting(SpreadsheetSelection(sheets: .names(["other"]))))
        XCTAssertEqual(try workbook.selecting(SpreadsheetSelection(sheets: .indices(IndexSelection("2")))).sheets.first?.sourceIndex, 2)
        XCTAssertEqual(try workbook.selecting(SpreadsheetSelection(sheets: .names(["Other", "Other"]))).sheets.count, 1)
    }

    func testEmptyHiddenUnknownUnsupportedAndOutOfBoundsSelectionsAreControlled() throws {
        var workbook = SpreadsheetWorkbook(sheets: [sheet("Hidden")])
        workbook.sheets[0].visibility = .hidden
        XCTAssertThrowsError(try workbook.selecting(SpreadsheetSelection(sheets: .visible)))
        workbook.sheets[0].visibility = .unknown
        XCTAssertThrowsError(try workbook.selecting(SpreadsheetSelection(sheets: .visible)))
        XCTAssertEqual(try workbook.selecting(SpreadsheetSelection()).sheets.count, 1)
        XCTAssertThrowsError(try workbook.selecting(SpreadsheetSelection(sheets: .indices(IndexSelection("2")))))
        workbook.sheetSummaries = [.init(index: 1, name: "Hidden", visibility: .visible, isReadable: true), .init(index: 2, name: "Chart", visibility: .visible, isReadable: false)]
        XCTAssertThrowsError(try workbook.selecting(SpreadsheetSelection(sheets: .indices(IndexSelection("2")))))
        XCTAssertEqual(try workbook.selecting(SpreadsheetSelection()).sheets.count, 1)
    }

    func testMergeBoundaryDoesNotPullAnUnselectedAnchorIntoTheRange() throws {
        try withFixtures { _, sources in
            for source in sources {
                let parsed = try read(source)
                let selected = try parsed.selecting(SpreadsheetSelection(sheets: .indices(IndexSelection("1")), ranges: [SpreadsheetCellRange("B1:C1")]))
                let text = try SpreadsheetMarkdownRenderer.render(selected, sourceURL: source, style: .markdownTable)
                XCTAssertFalse(text.contains("1101"))
                XCTAssertTrue(parsed.hasFlattenedMerges)
                XCTAssertEqual(selected.sheets[0].originColumn, 1)
            }
        }
    }

    func testClippingDoesNotExpandOutsidePopulatedExtentOrMaterializeGaps() throws {
        let workbook = SpreadsheetWorkbook(sheets: [sheet("Small")])
        let selected = try workbook.selecting(SpreadsheetSelection(ranges: [SpreadsheetCellRange("A1:XFD1000000")]))
        XCTAssertEqual(selected.sheets[0].rows.count, 1)
        XCTAssertEqual(selected.sheets[0].rows[0].count, 1)
        let empty = try workbook.selecting(SpreadsheetSelection(ranges: [SpreadsheetCellRange("XFD1000000")]))
        XCTAssertTrue(empty.sheets[0].rows.isEmpty)
        XCTAssertTrue(try SpreadsheetMarkdownRenderer.render(empty, sourceURL: URL(fileURLWithPath: "/tmp/small.xlsx"), style: .markdownTable).contains("no populated cells"))
    }

    func testSelectedCellAvoidsUnselectedRectangularExpansionBudget() throws {
        var rows = Array(repeating: [SpreadsheetCell](), count: 1_000)
        rows[0] = Array(repeating: .empty, count: SpreadsheetLimits.maximumColumns)
        rows[0][SpreadsheetLimits.maximumColumns - 1] = .init(value: .string("FarMarker"), displayText: "FarMarker", formula: nil)
        rows[999] = [.init(value: .string("SelectedMarker"), displayText: "SelectedMarker", formula: nil)]
        let workbook = SpreadsheetWorkbook(sheets: [.init(name: "Sparse", rows: rows)])
        XCTAssertThrowsError(try SpreadsheetLimits.validate(workbook))
        let selected = try workbook.selecting(SpreadsheetSelection(ranges: [SpreadsheetCellRange("A1000")]))
        XCTAssertEqual(selected.sheets[0].rows.count, 1)
        XCTAssertEqual(selected.sheets[0].rows[0].count, 1)
        let text = try SpreadsheetMarkdownRenderer.render(selected, sourceURL: URL(fileURLWithPath: "/tmp/sparse.xlsx"), style: .markdownTable)
        XCTAssertTrue(text.contains("SelectedMarker")); XCTAssertFalse(text.contains("FarMarker"))
    }

    func testFormulaCachedResultsAreKeptWithoutFollowingExternalReferences() throws {
        try withFixtures { _, sources in
            for source in sources where source.pathExtension != "xls" {
                let selected = try read(source).selecting(SpreadsheetSelection(sheets: .indices(IndexSelection("1")), ranges: [SpreadsheetCellRange("B3")]))
                let cell = selected.sheets[0].rows[0][0]
                XCTAssertEqual(cell.displayText, "CachedOutside")
                XCTAssertNotNil(cell.formula)
                XCTAssertEqual(selected.sheets[0].originRow, 2)
            }
        }
    }

    func testCancellationWrongFormatAndInvalidSelectionLeaveNoOutput() throws {
        try withFixtures { root, sources in
            let source = sources[0], destination = root.appendingPathComponent("never")
            let token = ConversionCancellationToken(); token.cancel()
            XCTAssertThrowsError(try DocumentConverter().inspectSpreadsheetContents(source, cancellation: token)) { error in
                guard case ConversionError.cancelled = error else { return XCTFail("\(error)") }
            }
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination), options: .init(spreadsheetSelection: SpreadsheetSelection(sheets: .indices(IndexSelection("4")))))))
            let csv = root.appendingPathComponent("values.csv"); try Data("Name,Value\nMarker,1\n".utf8).write(to: csv)
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: csv, destination: .directory(destination), options: .init(spreadsheetSelection: SpreadsheetSelection()))))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
        }
    }

    func testODSDefaultAndInheritedTableVisibilityDoNotConflictWithCellStyles() throws {
        let xml = SpreadsheetSelectionFixture.odsXML().replacingOccurrences(of: "<office:automatic-styles>", with: "<office:automatic-styles><style:default-style style:family=\"table-cell\"/><style:default-style style:family=\"table\"><style:table-properties table:display=\"false\"/></style:default-style>")
        XCTAssertEqual(try ODSWorkbookParser.parse(Data(xml.utf8)).summaries.map(\.visibility), [.hidden, .hidden, .hidden])
    }

    private func sheet(_ name: String) -> SpreadsheetSheet { .init(name: name, rows: [[.init(value: .number("1"), displayText: "1", formula: nil)]]) }
    private func withFixtures(_ body: (URL, [URL]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTSpreadsheetSelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, SpreadsheetSelectionFixture.create(in: root))
    }
    private func read(_ source: URL) throws -> SpreadsheetWorkbook {
        switch source.pathExtension {
        case "xlsx": try XLSXWorkbookParser.parse(packageAt: source)
        case "ods": try ODSWorkbookParser.parse(Data(SpreadsheetSelectionFixture.odsXML().utf8))
        default: try LegacyXLSWorkbookParser.parse(Data(contentsOf: source))
        }
    }
}

enum SpreadsheetSelectionFixture {
    static let names = ["Visible", "Hidden", "VeryHidden"]
    static func create(in root: URL) throws -> [URL] {
        let sources = ["xlsx", "ods", "xls"].map { root.appendingPathComponent("selection." + $0) }
        try xlsx().write(to: sources[0])
        try ZIPFixtureBuilder.archive(entries: [.init(name: "mimetype", content: Data("application/vnd.oasis.opendocument.spreadsheet".utf8)), .init(name: "content.xml", content: Data(odsXML().utf8))]).write(to: sources[1])
        try xls().write(to: sources[2])
        return sources
    }

    static func xlsx() throws -> Data {
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main", rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var parts = ["[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/></Types>"]
        parts["xl/workbook.xml"] = "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(rel)\"><sheets>" + names.enumerated().map { "<sheet name=\"\($0.element)\" sheetId=\"\($0.offset + 1)\" r:id=\"r\($0.offset)\" state=\"\(["visible", "hidden", "veryHidden"][$0.offset])\"/>" }.joined() + "</sheets></workbook>"
        parts["xl/_rels/workbook.xml.rels"] = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + names.indices.map { "<Relationship Id=\"r\($0)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>" }.joined() + "</Relationships>"
        for sheet in 1...3 {
            let rows = (1...4).map { row in
                "<row r=\"\(row)\">" + (1...5).filter { !(row == 1 && (2...3).contains($0)) }.map { column in
                    let address = SpreadsheetCellRange.columnName(column) + String(row)
                    return row == 3 && column == 2 ? "<c r=\"\(address)\" t=\"str\"><f>VeryHidden!A1</f><v>CachedOutside</v></c>" : "<c r=\"\(address)\"><v>\(sheet * 1000 + row * 100 + column)</v></c>"
                }.joined() + "</row>"
            }.joined()
            parts["xl/worksheets/sheet\(sheet - 1).xml"] = "<worksheet xmlns=\"\(ns)\"><sheetData>\(rows)</sheetData><mergeCells><mergeCell ref=\"A1:C1\"/></mergeCells></worksheet>"
        }
        return try ZIPFixtureBuilder.archive(entries: parts.sorted { $0.key < $1.key }.map { .init(name: $0.key, content: Data($0.value.utf8)) })
    }

    static func odsXML() -> String {
        let namespaces = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\""
        let sheets = names.enumerated().map { offset, name in
            let rows = (1...4).map { row in
                "<table:table-row>" + (1...5).map { column in
                    if row == 1 && (2...3).contains(column) { return "<table:covered-table-cell/>" }
                    if row == 3 && column == 2 { return "<table:table-cell office:value-type=\"string\" table:formula=\"of:=VeryHidden.A1\"><text:p>CachedOutside</text:p></table:table-cell>" }
                    return "<table:table-cell office:value-type=\"float\" office:value=\"\((offset + 1) * 1000 + row * 100 + column)\"\(row == 1 && column == 1 ? " table:number-columns-spanned=\"3\"" : "")/>"
                }.joined() + "</table:table-row>"
            }.joined()
            return "<table:table table:name=\"\(name)\"\(offset > 0 ? " table:style-name=\"HiddenStyle\"" : "")>\(rows)</table:table>"
        }.joined()
        return "<office:document-content \(namespaces)><office:automatic-styles><style:style style:name=\"HiddenStyle\" style:family=\"table\"><style:table-properties table:display=\"false\"/></style:style></office:automatic-styles><office:body><office:spreadsheet>\(sheets)</office:spreadsheet></office:body></office:document-content>"
    }

    static func xls() throws -> Data {
        func le(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func record(_ id: UInt64, _ payload: Data) -> Data { le(id, 2) + le(UInt64(payload.count), 2) + payload }
        let bof = record(0x0809, le(0x0600, 2) + le(5, 2)), eof = record(0x000a, Data())
        let streams = (1...3).map { sheet -> Data in
            var result = record(0x0809, le(0x0600, 2) + le(0x10, 2))
            for row in 1...4 {
                for column in 1...5 where !(row == 1 && (2...3).contains(column)) {
                    result += record(0x0203, le(UInt64(row - 1), 2) + le(UInt64(column - 1), 2) + le(0, 2) + le(Double(sheet * 1000 + row * 100 + column).bitPattern, 8))
                }
            }
            result += record(0x00e5, le(1, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(2, 2))
            return result + eof
        }
        let directoryBytes = names.reduce(0) { $0 + 12 + $1.utf8.count }
        var offset = bof.count + directoryBytes + eof.count, globals = bof
        for index in names.indices {
            globals += record(0x0085, le(UInt64(offset), 4) + Data([UInt8(index), 0, UInt8(names[index].utf8.count), 0]) + Data(names[index].utf8))
            offset += streams[index].count
        }
        return try MSGEmbeddedWriter.compound([["Workbook"]: streams.reduce(globals + eof, +)])
    }
}
