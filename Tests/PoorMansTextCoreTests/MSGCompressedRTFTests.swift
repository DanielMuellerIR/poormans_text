import Foundation
import XCTest
@testable import PoorMansTextCore

final class MSGCompressedRTFTests: XCTestCase {
    func testUncompressedAndDamagedHeaders() throws {
        let rtf = Data(#"{\rtf1\ansi Hello}"#.utf8)
        var bytes = header(size: rtf.count) + rtf
        XCTAssertEqual(try MSGCompressedRTF.decode(bytes), rtf)
        bytes[12] = 1
        XCTAssertThrowsError(try MSGCompressedRTF.decode(bytes))
        bytes[12] = 0
        bytes[4] = 0
        XCTAssertThrowsError(try MSGCompressedRTF.decode(bytes))
        XCTAssertThrowsError(try MSGCompressedRTF.decode(Data(bytes.dropLast())))
    }

    func testCompressedDictionaryReferencesAgainstIndependentFixture() throws {
        // Mit compressed-rtf erzeugt; der erwartete Körper ist unabhängig vom Leser.
        let encoded = "JgAAACsAAABMWkZ10YSbWQMACgByY3BnMTI1YDIgSGVsCQAOaiECfQ+g"
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertEqual(try MSGCompressedRTF.decode(data), Data(#"{\rtf1\ansi\ansicpg1252 Hello Hello Hello!}"#.utf8))
        var broken = data
        broken[16] ^= 1
        XCTAssertThrowsError(try MSGCompressedRTF.decode(broken))
    }

    func testExternalCompressedBodiesMatchIndependentDecoder() throws {
        guard let path = ProcessInfo.processInfo.environment["POORMANS_MSG_RTF_REFERENCE"] else {
            throw XCTSkip("External compressed RTF corpus not configured")
        }
        struct Body: Decodable { let compressed: String; let rtf: String }
        let refs = try JSONDecoder().decode([Body].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThanOrEqual(refs.count, 1)
        for ref in refs {
            let data = try XCTUnwrap(Data(base64Encoded: ref.compressed))
            let expected = try XCTUnwrap(Data(base64Encoded: ref.rtf))
            XCTAssertEqual(try MSGCompressedRTF.decode(data), expected)
            var damaged = data
            damaged[damaged.count - 1] ^= 1
            XCTAssertThrowsError(try MSGCompressedRTF.decode(damaged))
            var wrongSize = data
            wrongSize[4] ^= 1
            XCTAssertThrowsError(try MSGCompressedRTF.decode(wrongSize))
        }
    }

    private func header(size: Int) -> Data {
        var data = Data(repeating: 0, count: 16)
        for (offset, number) in [(0, UInt32(size + 12)), (4, UInt32(size)), (8, UInt32(0x414C454D))] {
            for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: number >> (i * 8)) }
        }
        return data
    }
}
