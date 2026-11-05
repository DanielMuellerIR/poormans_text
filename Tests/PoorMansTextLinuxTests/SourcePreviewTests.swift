#if os(Linux)
import Foundation
import Glibc
import XCTest
@testable import PoorMansTextCore

final class SourcePreviewTests: XCTestCase {
    func testInvalidIndexFailsWithoutOpeningSource() throws {
        XCTAssertThrowsError(try DocumentConverter().renderSourcePreview(URL(fileURLWithPath: "/missing-preview-source"), selection: .page(0))) {
            guard case ConversionError.invalidInput = $0 else { return XCTFail("unexpected error: \($0)") }
        }
    }

    func testSourceLimitRejectsSparseFileBeforeDecoder() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("pmt-preview-limit-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: source) }
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(SourcePreview.maximumSourceBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try DocumentConverter().renderSourcePreview(source, selection: .frame(1))) {
            guard case ConversionError.invalidInput = $0 else { return XCTFail("unexpected error: \($0)") }
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber,
                       NSNumber(value: SourcePreview.maximumSourceBytes + 1))
    }

    func testFIFOIsRejectedWithoutBlockingOrDecoder() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("pmt-preview-fifo-\(UUID().uuidString)")
        XCTAssertEqual(mkfifo(source.path, 0o600), 0)
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertThrowsError(try DocumentConverter().renderSourcePreview(source, selection: .frame(1))) {
            guard case ConversionError.invalidInput = $0 else { return XCTFail("unexpected error: \($0)") }
        }
    }

    func testPrecancelledPreviewRetainsCancellation() throws {
        let cancellation = ConversionCancellationToken()
        cancellation.cancel()
        XCTAssertThrowsError(try DocumentConverter().renderSourcePreview(URL(fileURLWithPath: "/missing-preview-source"), selection: .page(1), cancellation: cancellation)) {
            guard case ConversionError.cancelled = $0 else { return XCTFail("unexpected error: \($0)") }
        }
    }
}
#endif
