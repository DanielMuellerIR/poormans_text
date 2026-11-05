import Foundation
import XCTest
import Glibc
@testable import PoorMansTextCore
final class LinuxStructuredRuntimeInventoryTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private var record: LinuxStructuredOCR.RuntimeFile {
        .init(sha256: ConversionFileFingerprint.digest(Data("verified".utf8)), byteCount: 8)
    }
    func testExactNestedInventoryPasses() throws {
        try fixture { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: false)
            try Data("verified".utf8).write(to: root.appendingPathComponent("bin/python"))
            XCTAssertNoThrow(try LinuxStructuredOCR.validateInventory(root, files: ["bin/python": record]))
        }
    }
    func testDirectoryOpenedBeforePopulationIsFullyVerified() throws {
        try fixture { root in
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            try Data("verified".utf8).write(to: root.appendingPathComponent("payload"))
            XCTAssertNoThrow(try LinuxStructuredOCR.validateInventory(descriptor: descriptor,
                root: root, files: ["payload": record], manifest: nil))
            try Data("modified".utf8).write(to: root.appendingPathComponent("payload"))
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(descriptor: descriptor,
                root: root, files: ["payload": record], manifest: nil))
        }
    }
    func testRepeatedDescriptorValidationDoesNotConsumeCallerOffset() throws {
        try fixture { root in
            try Data("verified".utf8).write(to: root.appendingPathComponent("payload"))
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            let offset = lseek(descriptor, 0, SEEK_CUR)
            try LinuxStructuredOCR.validateInventory(descriptor: descriptor, root: root, files: ["payload": record], manifest: nil)
            XCTAssertEqual(lseek(descriptor, 0, SEEK_CUR), offset)
            XCTAssertNoThrow(try LinuxStructuredOCR.validateInventory(descriptor: descriptor, root: root, files: ["payload": record], manifest: nil))
        }
    }
    func testInteriorFileAndDirectorySymlinksReject() throws {
        try fixture { root in
            try Data("verified".utf8).write(to: root.appendingPathComponent("target"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "target")
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: ["target": record, "alias": record]))
        }
        try fixture { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: false)
            try Data("verified".utf8).write(to: root.appendingPathComponent("real/value"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "real")
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: ["real/value": record, "alias/value": record]))
        }
    }
    func testManifestSymlinkAlsoRejects() throws {
        try fixture { root in
            try Data("verified".utf8).write(to: root.appendingPathComponent("target"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("runtime-manifest.json").path, withDestinationPath: "target")
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: ["target": record], manifest: record))
        }
    }
    func testExtraEmptyDirectoryRejects() throws {
        try fixture { root in
            try Data("verified".utf8).write(to: root.appendingPathComponent("payload"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("extra"), withIntermediateDirectories: false)
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: ["payload": record]))
        }
    }
    func testHardlinksAndFIFOReject() throws {
        try fixture { root in
            let first = root.appendingPathComponent("payload")
            try Data("verified".utf8).write(to: first)
            XCTAssertEqual(link(first.path, root.appendingPathComponent("alias").path), 0)
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: ["payload": record, "alias": record]))
        }
        try fixture { root in
            XCTAssertEqual(mkfifo(root.appendingPathComponent("payload").path, 0o600), 0)
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: ["payload": record]))
        }
    }
    func testUnreadableDirectoryTraversalRejects() throws {
        try fixture { root in
            let directory = root.appendingPathComponent("blocked")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("verified".utf8).write(to: directory.appendingPathComponent("payload"))
            XCTAssertEqual(chmod(directory.path, 0), 0)
            defer { _ = chmod(directory.path, 0o700) }
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: ["blocked/payload": record]))
        }
    }
    func testPathTraversalDepthAndByteLimitsReject() throws {
        try fixture { root in
            for key in ["a\\b", "a\nb", String(repeating: "x", count: 256), "../escape", "/absolute", "a//b", String(repeating: "x", count: 4097), String(repeating: "é", count: 2049), Array(repeating: "a", count: 65).joined(separator: "/")] {
                XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: [key: record]), key)
            }
        }
    }
    func testMissingAndChangedFilesReject() throws {
        try fixture { root in
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: ["payload": record]))
            try Data("modified".utf8).write(to: root.appendingPathComponent("payload"))
            XCTAssertThrowsError(try LinuxStructuredOCR.validateInventory(root, files: ["payload": record]))
        }
    }
}
