import Foundation
import XCTest
@testable import PoorMansTextCore

final class MSGEmbeddedWriterTests: XCTestCase {
    func testSmallLargeEmptyAndSameNamedStreamsRoundTrip() throws {
        let values: [[String]: Data] = [
            ["Small"]: Data([1, 2, 3]), ["Large"]: Data(repeating: 4, count: 5000),
            ["Other", "Small"]: Data([5, 6]), ["Empty"]: Data()
        ]
        let data = try MSGEmbeddedWriter.compound(values)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".msg")
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let tree = try OLECompoundDocument(data: Data(contentsOf: source)).storageTree()
        XCTAssertEqual(Set(tree.streamPaths), Set(values.keys))
        for (path, expected) in values { XCTAssertEqual(try tree.stream(at: path), expected) }
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testDIFATAndMiniStreamsTogether() throws {
        let large = Data(repeating: 17, count: 8_000_000)
        let values: [[String]: Data] = [["Large"]: large, ["Storage", "Small"]: Data([3, 4])]
        let bytes = try MSGEmbeddedWriter.compound(values)
        XCTAssertGreaterThan(bytes.legacyUInt32(at: 72), 0)
        let tree = try OLECompoundDocument(data: bytes).storageTree()
        XCTAssertEqual(try tree.stream(at: ["Large"]), large)
        XCTAssertEqual(try tree.stream(at: ["Storage", "Small"]), Data([3, 4]))
    }

    func testExternalEmbeddedMessageRetainsAllValueStreams() throws {
        guard let root = ProcessInfo.processInfo.environment["POORMANS_MSG_CORPUS"] else {
            throw XCTSkip("External MSG corpus not configured")
        }
        let source = URL(fileURLWithPath: root).appendingPathComponent("EmailWithInnerMailAndAttachments.msg")
        let before = try Data(contentsOf: source)
        let tree = try OLECompoundDocument(data: before).storageTree()
        let embedded = try XCTUnwrap(tree.streamPaths.first {
            $0.last == "__properties_version1.0" && $0.dropLast().last == "__substg1.0_3701000D"
        })
        let storage = Array(embedded.dropLast())
        let exported = try MSGEmbeddedWriter.export(tree, storage: storage)
        let standalone = try OLECompoundDocument(data: exported).storageTree()
        for path in tree.streamPaths where path.starts(with: storage) {
            let relative = Array(path.dropFirst(storage.count))
            let original = try XCTUnwrap(tree.stream(at: path))
            let copied = try XCTUnwrap(standalone.stream(at: relative))
            if relative == ["__properties_version1.0"] {
                XCTAssertEqual(copied.prefix(24), original.prefix(24))
                XCTAssertEqual(copied.dropFirst(32), original.dropFirst(24))
                _ = try MSGProperties(data: copied, kind: .root)
            } else { XCTAssertEqual(copied, original) }
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
        if let output = ProcessInfo.processInfo.environment["POORMANS_MSG_EXPORT_CHECK"] {
            try exported.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
