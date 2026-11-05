#if os(Linux)
import XCTest
import Foundation
@testable import PoorMansTextCore

final class LinuxOCRTests: XCTestCase {
    private let header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n"
    func testLanguageMappingRequiresActuallyInstalledData() throws {
        XCTAssertEqual(try LinuxOCR.resolveLanguages(["de-DE", "en", "deu"], available: ["deu", "eng", "osd"]), ["deu", "eng"])
        XCTAssertEqual(try LinuxOCR.resolveLanguages([], available: ["deu", "eng"]), ["eng"])
        XCTAssertThrowsError(try LinuxOCR.resolveLanguages(["fr"], available: ["eng"]))
        XCTAssertThrowsError(try LinuxOCR.resolveLanguages(["../eng"], available: ["eng"]))
        XCTAssertThrowsError(try LinuxOCR.resolveLanguages(["--"], available: ["eng"]))
        XCTAssertEqual(try LinuxOCR.resolveLanguages(["zh-Hant-TW"], available: ["chi_sim", "chi_tra"]), ["chi_tra"])
        XCTAssertThrowsError(try LinuxOCR.resolveLanguages(["zh-Hant"], available: ["chi_sim"]))
    }
    func testTSVPreservesLineOrderAndNormalizesBottomLeftGeometry() throws {
        let tsv = header + "1\t1\t0\t0\t0\t0\t0\t0\t200\t100\t-1\t\n5\t1\t1\t1\t1\t1\t20\t10\t40\t20\t98\tALPHA\n5\t1\t1\t1\t1\t2\t70\t10\t30\t20\t96\tBETA\n"
        let result = try LinuxOCR.parseTSV(tsv, width: 200, height: 100)
        XCTAssertEqual(result.text, "ALPHA BETA")
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].bounds.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.lines[0].bounds.minY, 0.7, accuracy: 0.0001)
        XCTAssertEqual(result.lines[0].bounds.width, 0.4, accuracy: 0.0001)
    }
    func testTSVRejectsOutOfRasterAndMissingPage() throws {
        XCTAssertThrowsError(try LinuxOCR.parseTSV(header + "5\t1\t1\t1\t1\t1\t0\t0\t1\t1\t90\tX\n", width: 10, height: 10))
        XCTAssertThrowsError(try LinuxOCR.parseTSV(header + "1\t1\t0\t0\t0\t0\t0\t0\t200\t100\t-1\t\n", width: 10, height: 10))
    }
    func testTSVLowConfidenceIsVisibleAndControlsAreRemoved() throws {
        let tsv = header + "1\t1\t0\t0\t0\t0\t0\t0\t20\t20\t-1\t\n5\t1\t1\t1\t1\t1\t1\t1\t10\t10\t20\tAL\u{0}PHA\n"
        let result = try LinuxOCR.parseTSV(tsv, width: 20, height: 20)
        XCTAssertEqual(result.lines[0].recognized, "ALPHA")
        XCTAssertEqual(result.text, "[OCR uncertain: ALPHA]")
    }
    func testActualLocalRasterRecognition() throws {
        guard let fixture = ProcessInfo.processInfo.environment["PMT_OCR_FIXTURE"] else { throw XCTSkip("Host OCR fixture not selected") }
        let result = try LinuxOCR.recognize(pngURL: URL(fileURLWithPath: fixture), languages: ["de", "en"])
        XCTAssertTrue(result.text.contains("ALPHA"), result.text)
        XCTAssertFalse(result.lines.isEmpty)
        XCTAssertTrue(result.lines.allSatisfy { $0.bounds.minX >= 0 && $0.bounds.minY >= 0 && $0.bounds.maxX <= 1 && $0.bounds.maxY <= 1 })
    }
}
#endif
