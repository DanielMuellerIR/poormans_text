import Foundation
#if os(Linux)
import FoundationXML
#endif
import XCTest
@testable import PoorMansTextCore

final class PortableCoreTests: XCTestCase {
    func testCSVQuotesUnicodeAndReportPreserveAllNineCellsAndSourceBytes() throws {
        try withRoot { root in
            let bytes = Data("Name,Notiz,Wert\r\n\"Müller, Ä\",\"Er sagte \"\"Grüß dich\"\"\",12\r\nβ,\"erste\nzweite\",7\r\n".utf8)
            let source = root.appendingPathComponent("Tabelle ä.csv")
            try bytes.write(to: source)
            let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(conversionReport: true)))
            let markdownBytes = try Data(contentsOf: result.markdownFile)
            let markdown = try XCTUnwrap(String(data: markdownBytes, encoding: .utf8))
            XCTAssertEqual(tableRows(markdown), [
                ["Name", "Notiz", "Wert"],
                ["Müller, Ä", "Er sagte \"Grüß dich\"", "12"],
                ["β", "erste<br>zweite", "7"],
            ])
            XCTAssertEqual(result.sourceMappings.count, 9)
            XCTAssertEqual(Set(result.sourceMappings.compactMap { $0.source.cell }), Set(["A1", "B1", "C1", "A2", "B2", "C2", "A3", "B3", "C3"]))
            for mapping in result.sourceMappings { XCTAssertNotNil(mapping.output.text(in: markdownBytes)) }
            // Unabhängig vorab berechneter SHA-256 dieser festen UTF-8-Quelldaten.
            XCTAssertEqual(result.sourceIdentity?.sha256, "8e9bacde388722cd0393a8b17c8eb4b559a7879307789f44255146188364f06c")
            XCTAssertEqual(result.sourceIdentity?.byteCount, bytes.count)
            let report = try JSONDecoder().decode(ConversionReport.self, from: Data(contentsOf: XCTUnwrap(result.reportFile)))
            XCTAssertEqual(report.schemaVersion, 1)
            XCTAssertEqual(report.source.sha256, result.sourceIdentity?.sha256)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testOutputCollisionPreservesExistingTreeAndSource() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("source.csv")
            let bytes = Data("Key,Value\nAlpha,12\n".utf8)
            try bytes.write(to: source)
            let output = root.appendingPathComponent("existing")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let sentinel = output.appendingPathComponent("sentinel")
            try Data("OLD".utf8).write(to: sentinel)
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(output)))) {
                guard case ConversionError.outputAlreadyExists = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("OLD".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["sentinel"])
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(["existing", "source.csv"]))
        }
    }

    func testCancellationAfterConversionPublishesNeitherMarkdownNorReport() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("source.csv")
            let bytes = Data("Key,Value\nAlpha,12\n".utf8)
            try bytes.write(to: source)
            let token = ConversionCancellationToken()
            let output = root.appendingPathComponent("cancelled")
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(output), options: .init(conversionReport: true)), progress: { event in
                if event.phase == .publishing { token.cancel() }
            }, cancellation: token)) {
                guard case ConversionError.cancelled = $0 else { return XCTFail("\($0)") }
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.csv"])
        }
    }

    func testNotebookRetainsMarkdownCodeAndSavedOutputWithoutExecutingCode() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("notebook.ipynb")
            let sentinel = root.appendingPathComponent("must-not-exist")
            let code = "from pathlib import Path\nPath(\"\(sentinel.path)\").write_text(\"executed\")\nprint(\"CODETOKEN\")"
            let cells: [[String: Any]] = [
                ["cell_type": "markdown", "source": ["MARKDOWNTOKEN Grüße 😀"]],
                ["cell_type": "code", "source": code, "outputs": [
                    ["output_type": "stream", "text": ["STREAMTOKEN\n"]],
                    ["output_type": "execute_result", "data": ["text/plain": ["RESULTTOKEN"]]],
                ]],
                ["cell_type": "raw", "source": "RAWTOKEN"],
            ]
            let bytes = try JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": 5, "metadata": ["language_info": ["name": "python"]], "cells": cells], options: [.sortedKeys])
            try bytes.write(to: source)
            let result = try DocumentConverter().convert(.init(inputURL: source))
            let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
            for token in ["MARKDOWNTOKEN", "CODETOKEN", "STREAMTOKEN", "RESULTTOKEN", "RAWTOKEN"] {
                XCTAssertEqual(text.components(separatedBy: token).count - 1, 1, token)
            }
            XCTAssertTrue(text.contains("```python\n" + code + "\n```"), text)
            XCTAssertTrue(text.contains("Grüße 😀"))
            XCTAssertLessThan(try XCTUnwrap(text.range(of: "MARKDOWNTOKEN")).lowerBound, try XCTUnwrap(text.range(of: "CODETOKEN")).lowerBound)
            XCTAssertLessThan(try XCTUnwrap(text.range(of: "CODETOKEN")).lowerBound, try XCTUnwrap(text.range(of: "STREAMTOKEN")).lowerBound)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testStoredXLSXConvertsAllSixCellsWithoutChangingArchiveBytes() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("workbook.xlsx")
            let bytes = storedZIP(xlsxParts())
            try bytes.write(to: source)
            let result = try DocumentConverter().convert(.init(inputURL: source, options: .init(sourceMapping: true)))
            XCTAssertEqual(result.format, .xlsx)
            let markdown = try Data(contentsOf: result.markdownFile)
            XCTAssertEqual(tableRows(String(decoding: markdown, as: UTF8.self)), [["Name", "Count"], ["Äpfel", "12"], ["Birnen 😀", "7"]])
            XCTAssertEqual(result.sourceMappings.count, 6)
            XCTAssertEqual(Set(result.sourceMappings.compactMap { $0.source.cell }), Set(["A1", "B1", "A2", "B2", "A3", "B3"]))
            for mapping in result.sourceMappings { XCTAssertNotNil(mapping.output.text(in: markdown)) }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testFoundationXMLRestoresShadowedAttributeNamespace() {
        let collector = PortableNamespaceCollector()
        let xml = Data("<root xmlns:r='urn:expected'><item r:id='outer'/><group xmlns:r='urn:foreign'><item r:id='foreign'/></group><item r:id='restored'/></root>".utf8)
        XCTAssertTrue(ImportXMLParser.make(xml, delegate: collector).parse())
        XCTAssertEqual(collector.values, ["outer", nil, "restored"])
    }

    func testRTFCP1252AndUnicodeProtectionRequiresNoExternalTool() throws {
        let bytes = Data(#"{\rtf1\ansi\ansicpg1252 Gr\'fc\'dfe \u945?}"#.utf8)
        let protected = try RTFUnicodeProtector.protect(bytes)
        let restored = try protected.restoringUnicode(in: String(decoding: protected.data, as: UTF8.self))
        for entity in ["&#252;", "&#223;", "&#945;"] { XCTAssertEqual(restored.components(separatedBy: entity).count - 1, 1) }
        XCTAssertFalse(restored.contains("�"))
        XCTAssertEqual(bytes, Data(#"{\rtf1\ansi\ansicpg1252 Gr\'fc\'dfe \u945?}"#.utf8))
    }

    private func withRoot(_ operation: (URL) throws -> Void) throws {
        // /tmp kann auf macOS ein äußerer Symlink sein; getestet wird sein reales Verzeichnis.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PMTPortable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }

    private func tableRows(_ text: String) -> [[String]] {
        text.split(separator: "\n").filter { $0.hasPrefix("|") }.compactMap { line in
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { return nil }
            return cells
        }
    }

    private func xlsxParts() -> [(String, String)] {
        [
            ("[Content_Types].xml", "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Override PartName='/xl/workbook.xml' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml'/><Override PartName='/xl/worksheets/sheet1.xml' ContentType='application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'/></Types>"),
            ("_rels/.rels", "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='xl/workbook.xml'/></Relationships>"),
            ("xl/workbook.xml", "<workbook xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main' xmlns:r='http://schemas.openxmlformats.org/officeDocument/2006/relationships'><sheets><sheet name='Data' sheetId='1' r:id='rId1'/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='rId1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet' Target='worksheets/sheet1.xml'/></Relationships>"),
            ("xl/worksheets/sheet1.xml", "<worksheet xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><sheetData><row r='1'><c r='A1' t='inlineStr'><is><t>Name</t></is></c><c r='B1' t='inlineStr'><is><t>Count</t></is></c></row><row r='2'><c r='A2' t='inlineStr'><is><t>Äpfel</t></is></c><c r='B2'><v>12</v></c></row><row r='3'><c r='A3' t='inlineStr'><is><t>Birnen 😀</t></is></c><c r='B3'><v>7</v></c></row></sheetData></worksheet>"),
        ]
    }

    // Unabhängiges Store-ZIP aus lokalen/zentralen Headern; keine Produkt-ZIP-API,
    // keine Apple-Kompression und kein externer Prozess für das Eingabefixture.
    private func storedZIP(_ entries: [(String, String)]) -> Data {
        var local = Data(), central = Data()
        for (name, text) in entries {
            let filename = Data(name.utf8), content = Data(text.utf8)
            let offset = UInt32(local.count), size = UInt32(content.count), checksum = crc32(content)
            append32(0x04034b50, to: &local)
            for value: UInt16 in [20, 0x0800, 0, 0, 0] { append16(value, to: &local) }
            for value in [checksum, size, size] { append32(value, to: &local) }
            append16(UInt16(filename.count), to: &local); append16(0, to: &local)
            local.append(filename); local.append(content)
            append32(0x02014b50, to: &central)
            for value: UInt16 in [20, 20, 0x0800, 0, 0, 0] { append16(value, to: &central) }
            for value in [checksum, size, size] { append32(value, to: &central) }
            for value: UInt16 in [UInt16(filename.count), 0, 0, 0, 0] { append16(value, to: &central) }
            append32(0, to: &central); append32(offset, to: &central); central.append(filename)
        }
        let centralOffset = UInt32(local.count), centralSize = UInt32(central.count)
        local.append(central); append32(0x06054b50, to: &local)
        for value: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { append16(value, to: &local) }
        append32(centralSize, to: &local); append32(centralOffset, to: &local); append16(0, to: &local)
        return local
    }

    private func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        }
        return ~value
    }

    private func append16(_ value: UInt16, to bytes: inout Data) {
        bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func append32(_ value: UInt32, to bytes: inout Data) {
        append16(UInt16(truncatingIfNeeded: value), to: &bytes); append16(UInt16(truncatingIfNeeded: value >> 16), to: &bytes)
    }
}

private final class PortableNamespaceCollector: NSObject, XMLParserDelegate {
    let namespaces = NamespacePrefixTracker()
    var values: [String?] = []
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { namespaces.startMapping(prefix: prefix, uri: namespaceURI) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { namespaces.endMapping(prefix: prefix) }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "item" { values.append(namespaces.attributeValue(localName: "id", namespaceURI: "urn:expected", in: attributeDict)) }
    }
}
