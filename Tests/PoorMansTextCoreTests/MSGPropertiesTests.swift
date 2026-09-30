import Foundation
import XCTest
@testable import PoorMansTextCore

final class MSGPropertiesTests: XCTestCase {
    func testUnicodeAndANSIUseDeclaredByteCounts() throws {
        let text = "Grüße 日本 😀"
        let unicode = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        let tag: UInt32 = 0x0037001F
        let properties = try MSGProperties(data: table(tag, value: UInt32(unicode.count + 2)), kind: .root)
        XCTAssertEqual(try properties.decodedString(unicode, for: tag, ansiEncoding: .windowsCP1252), text)
        let ansi = Data([0x47, 0x72, 0xFC, 0xDF, 0x65])
        let ansiTag: UInt32 = 0x0037001E
        let legacy = try MSGProperties(data: table(ansiTag, value: 6), kind: .root)
        XCTAssertEqual(try legacy.decodedString(ansi, for: ansiTag, ansiEncoding: .windowsCP1252), "Grüße")
    }

    func testRejectsBadTablesStringsAndValueSizes() throws {
        XCTAssertThrowsError(try MSGProperties(data: Data(repeating: 0, count: 31), kind: .root))
        XCTAssertThrowsError(try MSGProperties(data: Data(repeating: 0, count: 49), kind: .root))
        let valid = table(0x0037001F, value: 4)
        XCTAssertThrowsError(try MSGProperties(data: valid + valid.suffix(16), kind: .root))
        let properties = try MSGProperties(data: valid, kind: .root)
        XCTAssertThrowsError(try properties.checkedValue(Data([1]), for: 0x0037001F))
        XCTAssertThrowsError(try properties.checkedValue(Data([1, 2]), for: 0x0038001F))
        for invalid in [Data([0, 0xD8])] {
            XCTAssertThrowsError(try properties.decodedString(invalid, for: 0x0037001F, ansiEncoding: .windowsCP1252))
        }
        let odd = try MSGProperties(data: table(0x0037001F, value: 3), kind: .root)
        XCTAssertThrowsError(try odd.decodedString(Data([65]), for: 0x0037001F, ansiEncoding: .windowsCP1252))
        let empty = try MSGProperties(data: table(0x0037001F, value: 2), kind: .root)
        XCTAssertEqual(try empty.decodedString(Data(), for: 0x0037001F, ansiEncoding: .windowsCP1252), "")
        let terminated = try MSGProperties(data: table(0x0037001F, value: 6), kind: .root)
        XCTAssertEqual(try terminated.decodedString(Data([65, 0, 0, 0]), for: 0x0037001F, ansiEncoding: .windowsCP1252), "A")
        let internalNull = try MSGProperties(data: table(0x0037001F, value: 8), kind: .root)
        XCTAssertThrowsError(try internalNull.decodedString(Data([65, 0, 0, 0, 66, 0]), for: 0x0037001F, ansiEncoding: .windowsCP1252))
    }

    func testFixedIntegersAndObjectHeaders() throws {
        for kind in [MSGProperties.ObjectKind.root, .embedded, .object] {
            let properties = try MSGProperties(data: table(0x37050003, value: 5, header: kind.headerSize), kind: kind)
            XCTAssertEqual(properties.integer(0x3705), 5)
            XCTAssertNil(properties.integer(0x3704))
        }
    }

    func testExternalPropertyStoresMatchIndependentReference() throws {
        guard let path = ProcessInfo.processInfo.environment["POORMANS_MSG_PROPERTY_REFERENCE"] else {
            throw XCTSkip("External MSG property corpus not configured")
        }
        struct Value: Decodable { let tag: UInt32; let base64: String; let unicode: String? }
        struct Store: Decodable {
            let file: String; let storage: [String]; let kind: String; let properties: String; let values: [Value]
        }
        let reference = URL(fileURLWithPath: path)
        let stores = try JSONDecoder().decode([Store].self, from: Data(contentsOf: reference))
        XCTAssertGreaterThanOrEqual(stores.count, 1)
        for store in stores {
            let kind = try XCTUnwrap(MSGProperties.ObjectKind(rawValue: store.kind))
            let bytes = try XCTUnwrap(Data(base64Encoded: store.properties))
            let properties = try MSGProperties(data: bytes, kind: kind)
            let source = reference.deletingLastPathComponent().appendingPathComponent(store.file)
            let before = try Data(contentsOf: source)
            let tree = try OLECompoundDocument(data: before).storageTree()
            XCTAssertEqual(try tree.stream(at: store.storage + ["__properties_version1.0"]), bytes)
            for value in store.values {
                let expected = try XCTUnwrap(Data(base64Encoded: value.base64))
                XCTAssertEqual(try properties.stream(value.tag, in: tree, storage: store.storage), expected)
                if let unicode = value.unicode {
                    XCTAssertEqual(try properties.decodedString(expected, for: value.tag, ansiEncoding: .windowsCP1252), unicode.hasSuffix("\0") ? String(unicode.dropLast()) : unicode)
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
        }
    }

    private func table(_ tag: UInt32, value: UInt32, header: Int = 32) -> Data {
        var bytes = Data(repeating: 0, count: header + 16)
        for (offset, number) in [(header, tag), (header + 4, 6), (header + 8, value)] {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: number >> (index * 8)) }
        }
        return bytes
    }
}
