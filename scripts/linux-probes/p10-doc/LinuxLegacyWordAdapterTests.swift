import Foundation
import XCTest
@testable import PoorMansTextCore

final class LinuxLegacyWordAdapterTests: XCTestCase {
    func testRealDOCIsDetectedByWordStreamAndXLSRemainsSpreadsheet() throws {
        let adapter = LinuxLegacyWordAdapter()
        for producer in ["libreoffice", "textutil"] {
            let source = fixture("WordProcessing/\(producer).doc")
            guard case .match(let inspection) = try adapter.inspectInput(at: source) else { return XCTFail("DOC was not detected") }
            XCTAssertEqual(inspection.format, .doc)
        }
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Spreadsheet.doc")
        try FileManager.default.copyItem(at: fixture("Spreadsheets/not-word.xls"), to: source)
        guard case .invalid(_, _, let reason) = try adapter.inspectInput(at: source) else { return XCTFail("XLS was mistaken for DOC") }
        XCTAssertTrue(reason.contains("WordDocument"))
        XCTAssertEqual(try DocumentConverter().detectFormat(at: source), .xls)
    }

    func testChangedSourceIsRejectedBeforeAnyExternalToolStarts() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("changed.doc")
        try FileManager.default.copyItem(at: fixture("WordProcessing/libreoffice.doc"), to: source)
        let adapter = LinuxLegacyWordAdapter()
        guard case .match = try adapter.inspectInput(at: source) else { return XCTFail("DOC was not detected") }
        let changed = Data("replaced source".utf8)
        try changed.write(to: source)
        let work = root.appendingPathComponent("work"), result = root.appendingPathComponent("result")
        for directory in [work, result] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        let context = AdapterConversionContext(inputURL: source, format: .doc,
            workDirectory: work, stagedOutputDirectory: result, options: .init())
        XCTAssertThrowsError(try adapter.convert(context)) {
            guard case ConversionError.invalidInput(_, let format, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(format, .doc)
        }
        XCTAssertEqual(try Data(contentsOf: source), changed)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: result.path).isEmpty)
    }

    func testIndependentTextComparisonReportsPartialLossAndRejectsSubstantialLoss() throws {
        let source = URL(fileURLWithPath: "/fixture.doc")
        XCTAssertNil(try LinuxLegacyWordAdapter.textDiagnostic(reference: "Grüße Ω", markdown: "**Grüße** Ω", inputURL: source))
        let warning = try XCTUnwrap(LinuxLegacyWordAdapter.textDiagnostic(reference: "one one one one one", markdown: "one one one one", inputURL: source))
        XCTAssertEqual(warning.code, "legacyWord.textContentLoss")
        XCTAssertEqual(warning.kind, .contentLoss)
        XCTAssertTrue(warning.message.contains("1 of 5"))
        XCTAssertThrowsError(try LinuxLegacyWordAdapter.textDiagnostic(reference: "one one one one one", markdown: "one", inputURL: source)) {
            guard case ConversionError.invalidInput(_, .doc, _) = $0 else { return XCTFail("\($0)") }
        }
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PoorMansTextCoreTests/Fixtures/\(name)")
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTLegacyDOC-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
