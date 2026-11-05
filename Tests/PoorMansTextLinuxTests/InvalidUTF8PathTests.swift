#if os(Linux)
import Foundation
import Glibc
import XCTest
@testable import PoorMansTextCore

final class InvalidUTF8PathTests: XCTestCase {
    private func withRoot(_ body: (URL, Int32) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTUTF8-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fd = Glibc.open(root.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        try body(root, fd)
    }
    private let rawName = Array("bad-".utf8) + [UInt8(0xFF)] + Array(".csv".utf8)
    private func raw<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
        try (bytes.map { CChar(bitPattern: $0) } + [0]).withUnsafeBufferPointer { try body($0.baseAddress!) }
    }
    private func writeRaw(_ bytes: [UInt8], in fd: Int32, data: Data) throws {
        let file = raw(bytes) { openat(fd, $0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        XCTAssertGreaterThanOrEqual(file, 0)
        defer { close(file) }
        XCTAssertEqual(data.withUnsafeBytes { Glibc.write(file, $0.baseAddress, $0.count) }, data.count)
    }
    private func readRaw(_ bytes: [UInt8], in fd: Int32) -> Data {
        let file = raw(bytes) { openat(fd, $0, O_RDONLY) }
        defer { close(file) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Glibc.read(file, &buffer, buffer.count)
        XCTAssertGreaterThanOrEqual(count, 0)
        return Data(buffer.prefix(max(0, count)))
    }
    private func assertUTF8Failure<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.contains("UTF-8"), "\($0)", file: file, line: line)
        }
    }
    func testValidReplacementCharacterFilenameWorksWithoutAnyRawInvalidSibling() throws {
        try withRoot { root, _ in
            let source = root.appendingPathComponent("bad-\u{FFFD}.csv")
            let data = Data("Key,Value\nVALID,42\n".utf8)
            try data.write(to: source)
            XCTAssertEqual(try InputEnumerator().enumerate([root]).map(\.url.path), [source.path])
            let result = try DocumentConverter().convert(.init(inputURL: source))
            XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("VALID"))
            XCTAssertEqual(try Data(contentsOf: source), data)
        }
    }
    func testRawInvalidSymlinkTargetCannotBeReplacedByAValidSiblingAtAnyPublicInspection() throws {
        try withRoot { root, fd in
            let original = Data("Key,Value\nRAW,7\n".utf8)
            try writeRaw(rawName, in: fd, data: original)
            let sibling = root.appendingPathComponent("bad-\u{FFFD}.csv")
            let siblingData = Data("Key,Value\nWRONGVALIDSIBLING,99\n".utf8)
            try siblingData.write(to: sibling)
            XCTAssertEqual(raw(rawName) { symlinkat($0, fd, "alias.csv") }, 0)
            let alias = root.appendingPathComponent("alias.csv"), converter = DocumentConverter()
            assertUTF8Failure { try converter.inspect(alias) }
            assertUTF8Failure { try converter.detectFormat(at: alias) }
            assertUTF8Failure { try converter.inspectSpreadsheetContents(alias) }
            assertUTF8Failure { try converter.inspectPresentationContents(alias) }
            assertUTF8Failure { try converter.inspectEPUBContents(alias) }
            assertUTF8Failure { try converter.inspectPDFContents(alias) }
            assertUTF8Failure { try InputEnumerator().enumerate([alias]) }
            let output = root.appendingPathComponent("result")
            assertUTF8Failure { try converter.convert(.init(inputURL: alias, destination: .directory(output))) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(readRaw(rawName, in: fd), original)
            XCTAssertEqual(try Data(contentsOf: sibling), siblingData)
            XCTAssertEqual(raw(rawName) { unlinkat(fd, $0, 0) }, 0)
            assertUTF8Failure { try converter.inspectPDFContents(alias) }
            XCTAssertEqual(try Data(contentsOf: sibling), siblingData)
        }
    }
    func testFolderCannotSilentlyOmitAnUnrepresentableName() throws {
        try withRoot { root, fd in
            let original = Data("Key,Value\nRAW,7\n".utf8)
            try writeRaw(rawName, in: fd, data: original)
            let sibling = root.appendingPathComponent("bad-\u{FFFD}.csv")
            let siblingData = Data("Key,Value\nSIBLING,42\n".utf8)
            try siblingData.write(to: sibling)
            assertUTF8Failure { try InputEnumerator().enumerate([root]) }
            XCTAssertEqual(readRaw(rawName, in: fd), original)
            XCTAssertEqual(try Data(contentsOf: sibling), siblingData)
        }
    }
    func testRTFDWithUnrepresentableEntryFailsWithoutPublishingOrReplacingSibling() throws {
        try withRoot { root, _ in
            let package = root.appendingPathComponent("source.rtfd")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            let fd = Glibc.open(package.path, O_RDONLY | O_DIRECTORY)
            defer { close(fd) }
            let original = Data("RAW-ASSET".utf8)
            try writeRaw(rawName, in: fd, data: original)
            let sibling = package.appendingPathComponent("bad-\u{FFFD}.csv")
            let siblingData = Data("VALID-ASSET".utf8)
            try siblingData.write(to: sibling)
            let rtf = Data(#"{\rtf1\ansi RTFMARKER}"#.utf8)
            try rtf.write(to: package.appendingPathComponent("TXT.rtf"))
            let output = root.appendingPathComponent("result")
            assertUTF8Failure { try DocumentConverter().convert(.init(inputURL: package, destination: .directory(output))) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(readRaw(rawName, in: fd), original)
            XCTAssertEqual(try Data(contentsOf: sibling), siblingData)
            XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("TXT.rtf")), rtf)
        }
    }
    func testNewDestinationThroughRawInvalidDirectoryAliasIsRejected() throws {
        try withRoot { root, fd in
            let name = Array("directory-".utf8) + [UInt8(0xFF)]
            XCTAssertEqual(raw(name) { mkdirat(fd, $0, 0o700) }, 0)
            XCTAssertEqual(raw(name) { symlinkat($0, fd, "output-alias") }, 0)
            let sibling = root.appendingPathComponent("directory-\u{FFFD}")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
            let sentinel = sibling.appendingPathComponent("sentinel")
            try Data("KEEP".utf8).write(to: sentinel)
            let source = root.appendingPathComponent("source.csv")
            let original = Data("Key,Value\nSOURCE,42\n".utf8)
            try original.write(to: source)
            let destination = root.appendingPathComponent("output-alias/result")
            assertUTF8Failure { try DocumentConverter().convert(.init(inputURL: source, destination: .directory(destination))) }
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("KEEP".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("result").path))
        }
    }
    func testFolderFilteringOrderAndPackageBoundaryRemainStable() throws {
        try withRoot { root, _ in
            for name in ["Chapter 10.csv", "Chapter 2.csv", "Nested/only.xlsx", ".hidden.csv", "old-markdown/skip.csv", ".hidden/skip.csv", "source.rtfd/inside.png"] {
                let file = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
            }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.csv"), withDestinationURL: root.appendingPathComponent("Chapter 2.csv"))
            let inputs = try InputEnumerator().enumerate([root])
            XCTAssertEqual(inputs.map { $0.url.lastPathComponent }, ["Chapter 2.csv", "Chapter 10.csv", "only.xlsx", "source.rtfd"])
            XCTAssertEqual(inputs[2].relativeDirectory, ["Nested"])
            XCTAssertFalse(InputEnumerator().isSearchableDirectory(root.appendingPathComponent("source.rtfd")))
        }
    }

}
#endif
