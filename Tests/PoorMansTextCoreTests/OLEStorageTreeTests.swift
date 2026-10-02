import Foundation
import XCTest
@testable import PoorMansTextCore

final class OLEStorageTreeTests: XCTestCase {
    func testSameNamedStreamsRemainInTheirOwnStorage() throws {
        let bytes = fixture()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".msg")
        try bytes.write(to: source, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: source) }
        let tree = try OLECompoundDocument(data: Data(contentsOf: source)).storageTree()
        XCTAssertEqual(tree.storageNames(in: []), ["Attachment"])
        XCTAssertEqual(tree.streamNames(in: []), ["Body"])
        XCTAssertEqual(tree.streamNames(in: ["attachment"]), ["Body"])
        XCTAssertEqual(try tree.stream(at: ["body"]), Data(repeating: 0x41, count: 4096))
        XCTAssertEqual(try tree.stream(at: ["Attachment", "BODY"]), Data(repeating: 0x42, count: 4096))
        XCTAssertNil(try tree.stream(at: ["Missing", "Body"]))
        XCTAssertNil(try tree.stream(at: ["Attachment"]))
        XCTAssertEqual(tree.streamPaths, [["Attachment", "Body"], ["Body"]])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testRejectsCyclesOutOfRangeIDsAliasesAndOrphans() throws {
        let directory = 17 * 512
        for (offset, value) in [
            (directory + 128 + 72, UInt32(1)),
            (directory + 128 + 72, UInt32(9999)),
            (directory + 256 + 76, UInt32(1)),
            (directory + 76, UInt32.max),
            (directory + 128 + 76, UInt32(3))
        ] {
            var bytes = fixture()
            put32(value, at: offset, in: &bytes)
            XCTAssertThrowsError(try OLECompoundDocument(data: bytes).storageTree())
        }
    }

    func testRejectsDuplicateNamesWithinOneStorage() throws {
        var bytes = fixture()
        let directory = 17 * 512
        let name = Array("BODY\0".utf16)
        for (index, unit) in name.enumerated() { put16(unit, at: directory + 256 + index * 2, in: &bytes) }
        put16(UInt16(name.count * 2), at: directory + 256 + 64, in: &bytes)
        XCTAssertThrowsError(try OLECompoundDocument(data: bytes).storageTree())
    }

    func testRejectsDamagedContainerAndStreamChain() throws {
        XCTAssertThrowsError(try OLECompoundDocument(data: Data(fixture().dropLast(512))))
        var bytes = fixture()
        put32(0, at: 18 * 512, in: &bytes)
        let tree = try OLECompoundDocument(data: bytes).storageTree()
        XCTAssertThrowsError(try tree.stream(at: ["Body"]))
    }

    func testRejectsRepeatedFATSectorsBeforeExpandingTheTable() throws {
        var bytes = fixture()
        put32(2, at: 44, in: &bytes)
        put32(17, at: 80, in: &bytes)
        XCTAssertThrowsError(try OLECompoundDocument(data: bytes)) { error in
            XCTAssertTrue(error.localizedDescription.contains("FAT"), error.localizedDescription)
        }
    }

    func testRejectsFATAndDIFATSectorOverlap() throws {
        var bytes = fixture()
        put32(17, at: 68, in: &bytes)
        put32(1, at: 72, in: &bytes)
        XCTAssertThrowsError(try OLECompoundDocument(data: bytes)) { error in
            XCTAssertTrue(error.localizedDescription.contains("FAT"), error.localizedDescription)
        }
    }

    func testBoundsDirectoryStorageBeforeParsingEntries() throws {
        XCTAssertEqual(try OLECompoundDocument(data: directoryFixture(sectors: 3125)).entryNames, ["Root Entry"])
        let bytes = directoryFixture(sectors: 3126)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ole")
        try bytes.write(to: source, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertThrowsError(try OLECompoundDocument(data: Data(contentsOf: source)))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private func directoryFixture(sectors: Int) -> Data {
        let sectorSize = 4096
        let fatSectors = 4
        var bytes = Data(repeating: 0, count: (1 + sectors + fatSectors) * sectorSize)
        bytes.replaceSubrange(0..<512, with: fixture().prefix(512))
        put16(4, at: 26, in: &bytes)
        put16(12, at: 30, in: &bytes)
        put32(UInt32(sectors), at: 40, in: &bytes)
        put32(UInt32(fatSectors), at: 44, in: &bytes)
        put32(0, at: 48, in: &bytes)
        for index in 0..<fatSectors { put32(UInt32(sectors + index), at: 76 + index * 4, in: &bytes) }
        bytes.replaceSubrange(sectorSize..<(sectorSize + 128), with: fixture()[(17 * 512)..<(17 * 512 + 128)])
        put32(.max, at: sectorSize + 76, in: &bytes)
        let fatOffset = (1 + sectors) * sectorSize
        bytes.replaceSubrange(fatOffset..<bytes.count, with: Data(repeating: 0xFF, count: fatSectors * sectorSize))
        for index in 0..<sectors {
            put32(index + 1 == sectors ? 0xFFFF_FFFE : UInt32(index + 1), at: fatOffset + index * 4, in: &bytes)
        }
        for index in 0..<fatSectors { put32(0xFFFF_FFFD, at: fatOffset + (sectors + index) * 4, in: &bytes) }
        return bytes
    }

    // Der unabhängige Referenzleser liefert jeden Stream als Bytes. Der Test
    // prüft auch alle Anhangs-/Unterobjekt-Streams, nicht nur sichtbaren Text.
    func testExternalMSGStreamsMatchIndependentReference() throws {
        guard let path = ProcessInfo.processInfo.environment["POORMANS_MSG_OLE_REFERENCE"] else {
            throw XCTSkip("External MSG corpus not configured")
        }
        struct Stream: Decodable { let path: [String]; let base64: String }
        struct File: Decodable { let name: String; let streams: [Stream] }
        let referenceURL = URL(fileURLWithPath: path)
        let files = try JSONDecoder().decode([File].self, from: Data(contentsOf: referenceURL))
        XCTAssertGreaterThanOrEqual(files.count, 1)
        for file in files {
            let source = referenceURL.deletingLastPathComponent().appendingPathComponent(file.name)
            let before = try Data(contentsOf: source)
            let tree = try OLECompoundDocument(data: before).storageTree()
            XCTAssertEqual(Set(tree.streamPaths), Set(file.streams.map(\.path)), file.name)
            for stream in file.streams {
                let expected = try XCTUnwrap(Data(base64Encoded: stream.base64))
                XCTAssertEqual(try tree.stream(at: stream.path), expected, file.name + ": stream byte mismatch")
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
        }
    }

    private func fixture() -> Data {
        var bytes = Data(repeating: 0, count: 19 * 512)
        bytes.replaceSubrange(0..<8, with: OLECompoundDocument.signature)
        put16(3, at: 26, in: &bytes)
        put16(0xFFFE, at: 28, in: &bytes)
        put16(9, at: 30, in: &bytes)
        put16(6, at: 32, in: &bytes)
        put32(1, at: 44, in: &bytes)
        put32(16, at: 48, in: &bytes)
        put32(4096, at: 56, in: &bytes)
        put32(0xFFFF_FFFE, at: 60, in: &bytes)
        put32(0xFFFF_FFFE, at: 68, in: &bytes)
        for index in 0..<109 { put32(.max, at: 76 + index * 4, in: &bytes) }
        put32(17, at: 76, in: &bytes)
        bytes.replaceSubrange(512..<4608, with: Data(repeating: 0x41, count: 4096))
        bytes.replaceSubrange(4608..<8704, with: Data(repeating: 0x42, count: 4096))
        entry("Root Entry", type: 5, id: 0, child: 1, start: 0xFFFF_FFFE, size: 0, in: &bytes)
        entry("Body", type: 2, id: 1, right: 2, start: 0, size: 4096, in: &bytes)
        entry("Attachment", type: 1, id: 2, child: 3, start: 0, size: 0, in: &bytes)
        entry("Body", type: 2, id: 3, start: 8, size: 4096, in: &bytes)
        for id in 0..<128 { put32(.max, at: 18 * 512 + id * 4, in: &bytes) }
        for id in 0..<16 {
            put32(id == 7 || id == 15 ? 0xFFFF_FFFE : UInt32(id + 1), at: 18 * 512 + id * 4, in: &bytes)
        }
        put32(0xFFFF_FFFE, at: 18 * 512 + 16 * 4, in: &bytes)
        put32(0xFFFF_FFFD, at: 18 * 512 + 17 * 4, in: &bytes)
        return bytes
    }

    private func entry(_ name: String, type: UInt8, id: Int, right: UInt32 = .max,
                       child: UInt32 = .max, start: UInt32, size: UInt32, in bytes: inout Data) {
        let offset = 17 * 512 + id * 128
        let units = Array((name + "\0").utf16)
        for (index, unit) in units.enumerated() { put16(unit, at: offset + index * 2, in: &bytes) }
        put16(UInt16(units.count * 2), at: offset + 64, in: &bytes)
        bytes[offset + 66] = type
        bytes[offset + 67] = 1
        put32(.max, at: offset + 68, in: &bytes)
        put32(right, at: offset + 72, in: &bytes)
        put32(child, at: offset + 76, in: &bytes)
        put32(start, at: offset + 116, in: &bytes)
        put32(size, at: offset + 120, in: &bytes)
    }

    private func put16(_ value: UInt16, at offset: Int, in bytes: inout Data) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func put32(_ value: UInt32, at offset: Int, in bytes: inout Data) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
