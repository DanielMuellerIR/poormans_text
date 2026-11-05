import Foundation
import XCTest
@testable import PoorMansTextCore

final class LinuxStructuredOCRTests: XCTestCase {
    private func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/linux-port/P11-DOCLING-EVIDENCE/documents/structured.json"))
    }
    func testApprovedRuntimeIsRequiredWithoutAnOverride() throws {
        XCTAssertThrowsError(try LinuxStructuredOCR.validateRuntime(URL(fileURLWithPath: "/tmp/missing-runtime"))) {
            XCTAssertTrue($0 is PlatformBackendUnavailable)
        }
    }
    func testRealDoclingTableUsesExistingRenderer() throws {
        let data = try fixture()
        let result = try LinuxStructuredOCR.project(data, width: 1800, height: 1600, dpiX: 299.9994, dpiY: 299.9994)
        XCTAssertTrue(result.page.markdown.contains("MERGED HEADER"))
        XCTAssertTrue(result.page.markdown.contains("TOTAL"))
        XCTAssertTrue(result.page.markdown.contains("|"))
        XCTAssertTrue(result.diagnostics.contains { $0.code == "ocr.structuredApproximation" })
    }
    func testRasterAspectMismatchCannotAdoptRecognition() throws {
        XCTAssertThrowsError(try LinuxStructuredOCR.project(fixture(), width: 200, height: 1))
    }
    func testMalformedJSONCannotAdoptRecognition() throws {
        XCTAssertThrowsError(try LinuxStructuredOCR.project(Data("{\"pages\":{},\"pages\":{}}".utf8), width: 10, height: 10))
    }
    func testOversizeAndDamagedPNGsCannotReachWorker() throws {
        var png = Data([137,80,78,71,13,10,26,10] + Array(repeating: UInt8(0), count: 16))
        png.replaceSubrange(16..<24, with: [0,0,0x10,0,0,0,0x10,0])
        XCTAssertThrowsError(try LinuxStructuredOCR.dimensions(png)) {
            XCTAssertTrue($0 is RasterImageValidationError)
        }
        png.replaceSubrange(16..<24, with: [0,0,0,1,0,0,0,1])
        XCTAssertThrowsError(try LinuxStructuredOCR.dimensions(png))
    }
    func testPhysicalResolutionIsBoundIndependentlyForBothAxes() throws {
        XCTAssertThrowsError(try LinuxStructuredOCR.project(fixture(), width: 1800, height: 1600))
        XCTAssertThrowsError(try LinuxStructuredOCR.project(fixture(), width: 1800, height: 1600, dpiX: 299.9994, dpiY: 72))
        XCTAssertThrowsError(try LinuxStructuredOCR.project(fixture(), width: 1800, height: 1600, dpiX: 299.9994))
    }
}
