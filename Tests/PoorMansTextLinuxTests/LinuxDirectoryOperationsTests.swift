import CPMTLinux
import Foundation
import Glibc
import XCTest

final class LinuxDirectoryOperationsTests: XCTestCase {
    func testDirectoryWithTrailingSlashUsesTheSameInode() throws {
        try withTestDirectory { root in
            let direct = pmt_process_open_directory(root.path)
            XCTAssertGreaterThanOrEqual(direct, 0)
            guard direct >= 0 else { return }
            defer { close(direct) }

            let trailingSlash = pmt_process_open_directory(root.path + "/")
            XCTAssertGreaterThanOrEqual(trailingSlash, 0)
            guard trailingSlash >= 0 else { return }
            defer { close(trailingSlash) }

            var first = stat()
            var second = stat()
            XCTAssertEqual(fstat(direct, &first), 0)
            XCTAssertEqual(fstat(trailingSlash, &second), 0)
            XCTAssertEqual(first.st_dev, second.st_dev)
            XCTAssertEqual(first.st_ino, second.st_ino)
        }
    }

    func testCleanupStopsAtItsDepthLimitAndRetainsTheRemainingTree() throws {
        try withTestDirectory { root in
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            var leaf = staging
            for _ in 0..<270 {
                leaf = leaf.appendingPathComponent("d", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
            let parent = pmt_process_open_directory(root.path)
            XCTAssertGreaterThanOrEqual(parent, 0)
            guard parent >= 0 else { return }
            defer { close(parent) }

            let result = pmt_remove_staging_at(parent, staging.lastPathComponent, -1)
            let error = errno
            XCTAssertEqual(result, -1)
            XCTAssertEqual(error, ELOOP)
            XCTAssertTrue(FileManager.default.fileExists(atPath: leaf.path))
        }
    }

    private func withTestDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
