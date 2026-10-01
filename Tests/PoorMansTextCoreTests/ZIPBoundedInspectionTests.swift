import Foundation
import XCTest
@testable import PoorMansTextCore

final class ZIPBoundedInspectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ZIPBounded-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testInspectionKeepsTheCheckedDescriptorAfterPathAndSymlinkReplacement() throws {
        let first = try write(try archive("first"), name: "first.zip")
        let second = try write(try archive("second"), name: "second.zip")
        let link = root.appendingPathComponent("input.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let snapshot = try ZIPArchiveInspector.inspectionSnapshot(at: link)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        try FileManager.default.removeItem(at: first)
        try Data("replacement".utf8).write(to: first)
        XCTAssertEqual(try snapshot.string(named: "mimetype"), "first")
    }

    func testTruncationFailsWithoutMappingTheForeignSource() throws {
        let source = try write(try ZIPFixtureBuilder.archive(entries: [
            .init(name: "large.xml", content: Data(repeating: 65, count: 262_144), isStored: true),
        ]))
        let snapshot = try ZIPArchiveInspector.inspectionSnapshot(at: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 0)
        try handle.close()
        XCTAssertThrowsError(try snapshot.data(named: "large.xml"))
    }

    func testCommentSignatureWithoutAnAlternativeDirectoryIsLiteral() throws {
        var bytes = try archive("plain")
        var comment = Data(repeating: 0x7F, count: 40)
        comment.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x05, 0x06])
        bytes.set16(comment.count, at: bytes.count - 2)
        bytes.append(comment)
        XCTAssertEqual(try inspect(bytes).entries["mimetype"], Data("plain".utf8))
    }

    func testDuplicateEndRecordWithTheSameDirectoryViewIsAccepted() throws {
        var bytes = try archive("plain")
        let end = Data(bytes.suffix(22))
        bytes.set16(23, at: bytes.count - 2)
        bytes.append(end)
        bytes.append(0x7F)
        XCTAssertEqual(try inspect(bytes).entries["mimetype"], Data("plain".utf8))
    }

    func testManyRepeatedEndPatternsWithOneDirectoryViewRemainBounded() throws {
        var bytes = try archive("plain")
        let repeated = Data(bytes.suffix(22))
        bytes.set16(2_900 * 22 + 1, at: bytes.count - 2)
        for _ in 0..<2_900 { bytes.append(repeated) }
        bytes.append(0x7F)
        XCTAssertEqual(try inspect(bytes).entries["mimetype"], Data("plain".utf8))
    }

    func testDifferentExtractorViewsAreRejectedEvenWhenTheLastEndIsNotTerminal() throws {
        var bytes = try ZIPFixtureBuilder.archive(entries: [
            .init(name: "mimetype", content: Data("safe".utf8), isStored: true),
            .init(name: "other.xml", content: Data("other".utf8), isStored: true),
        ])
        let primaryEnd = bytes.count - 22
        let firstCentral = bytes.value32(at: primaryEnd + 16)
        let otherCentral = firstCentral + 46 + "mimetype".utf8.count
        var alternative = Data(bytes.suffix(22))
        alternative.set16(1, at: 8)
        alternative.set16(1, at: 10)
        alternative.set32(primaryEnd - otherCentral, at: 12)
        alternative.set32(otherCentral, at: 16)
        let alternativeDirectory = Data(bytes[otherCentral..<primaryEnd])
        alternative.set32(bytes.count, at: 16)
        bytes.set16(alternativeDirectory.count + 23, at: primaryEnd + 20)
        bytes.append(alternativeDirectory)
        bytes.append(alternative)
        bytes.append(0x7F)
        let source = try write(bytes)
        // Python nimmt den letzten Schlussblock und sieht nur other.xml;
        // die frühere Dateiende-Regel sah dagegen beide Einträge.
        let python = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import zipfile,sys; print(','.join(zipfile.ZipFile(sys.argv[1]).namelist()))", source.path], currentDirectory: root, captureStandardOutput: true)
        XCTAssertEqual(python.status, 0, python.standardError)
        XCTAssertEqual(python.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "other.xml")
        let unzip = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z", "-1", source.path], currentDirectory: root, captureStandardOutput: true)
        XCTAssertEqual(unzip.status, 0, unzip.standardError)
        XCTAssertEqual(unzip.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "other.xml")
        XCTAssertThrowsError(try ZIPArchiveInspector.packageContents(at: source, entryNames: ["mimetype"])) {
            XCTAssertTrue($0.localizedDescription.contains("conflicting end records"), $0.localizedDescription)
        }
    }

    func testTwoTerminalEndRecordsWithDifferentViewsAreRejected() throws {
        var bytes = try archive("safe")
        let firstEnd = bytes.count - 22
        var emptyEnd = Data(bytes.suffix(22))
        emptyEnd.set16(0, at: 8)
        emptyEnd.set16(0, at: 10)
        emptyEnd.set32(0, at: 12)
        emptyEnd.set32(bytes.count, at: 16)
        bytes.set16(22, at: firstEnd + 20)
        bytes.append(emptyEnd)
        XCTAssertThrowsError(try inspect(bytes)) {
            XCTAssertTrue($0.localizedDescription.contains("conflicting end records"))
        }
    }

    func testUnexplainedGapAfterTheDirectoryIsRejected() throws {
        var bytes = try archive("plain")
        bytes.insert(contentsOf: [0x41, 0x42], at: bytes.count - 22)
        XCTAssertThrowsError(try inspect(bytes)) {
            XCTAssertTrue($0.localizedDescription.contains("unexplained gap"))
        }
    }

    func testDigitalSignatureIsAcceptedInsideOrAfterTheDeclaredDirectory() throws {
        for included in [false, true] {
            var bytes = try archive("plain")
            let end = bytes.count - 22
            let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x05, 3, 0, 0x41, 0x42, 0x43]
            if included { bytes.set32(bytes.value32(at: end + 12) + signature.count, at: end + 12) }
            bytes.insert(contentsOf: signature, at: end)
            XCTAssertEqual(try inspect(bytes).entries["mimetype"], Data("plain".utf8))
        }
    }

    func testTwoDirectorySignatureRecordsAreRejected() throws {
        var bytes = try archive("plain")
        let end = bytes.count - 22
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x05, 1, 0, 0x41]
        bytes.set32(bytes.value32(at: end + 12) + signature.count, at: end + 12)
        bytes.insert(contentsOf: signature + signature, at: end)
        XCTAssertThrowsError(try inspect(bytes)) {
            XCTAssertTrue($0.localizedDescription.contains("more than one digital signature"))
        }
    }

    func testArchiveExtraDataRecordIsAcceptedWithinTheDeclaredDirectory() throws {
        var bytes = try archive("plain")
        let end = bytes.count - 22
        let central = bytes.value32(at: end + 16)
        let extra: [UInt8] = [0x50, 0x4B, 0x06, 0x08, 3, 0, 0, 0, 0x41, 0x42, 0x43]
        bytes.set32(bytes.value32(at: end + 12) + extra.count, at: end + 12)
        bytes.insert(contentsOf: extra, at: central)
        XCTAssertEqual(try inspect(bytes).entries["mimetype"], Data("plain".utf8))
    }

    func testTruncatedSignatureAndExtraDataRecordsAreRejected() throws {
        for record: [UInt8] in [[0x50, 0x4B, 0x05, 0x05, 9, 0], [0x50, 0x4B, 0x06, 0x08, 99, 0, 0, 0]] {
            var bytes = try archive("plain")
            let end = bytes.count - 22
            let central = bytes.value32(at: end + 16)
            if record[2] == 6 {
                bytes.set32(bytes.value32(at: end + 12) + record.count, at: end + 12)
                bytes.insert(contentsOf: record, at: central)
            } else { bytes.insert(contentsOf: record, at: end) }
            XCTAssertThrowsError(try inspect(bytes))
        }
    }

    func testUnreferencedLocalEntryBeforeTheDirectoryIsRejected() throws {
        var bytes = try ZIPFixtureBuilder.archive(entries: [
            .init(name: "mimetype", content: Data("safe".utf8), isStored: true),
            .init(name: "hidden.xml", content: Data("hidden".utf8), isStored: true),
        ])
        let end = bytes.count - 22
        let central = bytes.value32(at: end + 16)
        let firstLength = 46 + "mimetype".utf8.count
        bytes.set16(1, at: end + 8)
        bytes.set16(1, at: end + 10)
        bytes.set32(firstLength, at: end + 12)
        bytes.removeSubrange((central + firstLength)..<end)
        XCTAssertThrowsError(try inspect(bytes)) {
            XCTAssertTrue($0.localizedDescription.contains("unexplained data"))
        }
    }

    func testDeflatePaddingWithinTheDeclaredEntryIsRejected() throws {
        var bytes = try ZIPFixtureBuilder.archive(entries: [.init(name: "mimetype", content: Data("safe".utf8))])
        let end = bytes.count - 22
        let central = bytes.value32(at: end + 16)
        let compressed = bytes.value32(at: central + 20)
        bytes.set32(compressed + 2, at: 18)
        bytes.set32(compressed + 2, at: central + 20)
        bytes.set32(central + 2, at: end + 16)
        bytes.insert(contentsOf: [0x41, 0x42], at: central)
        XCTAssertThrowsError(try inspect(bytes)) {
            XCTAssertTrue($0.localizedDescription.contains("compressed data"))
        }
        let work = root.appendingPathComponent("verified")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ZIPArchiveInspector.stageVerifiedPackage(from: write(bytes), into: work, named: "copy.zip")) {
            XCTAssertTrue($0.localizedDescription.contains("compressed data"))
        }
    }

    func testSignedAndUnsignedDataDescriptorsRemainSupported() throws {
        for signed in [false, true] {
            var bytes = try ZIPFixtureBuilder.archive(entries: [
                .init(name: "mimetype", content: Data("safe".utf8), isStored: true, explicitFlags: 8),
            ])
            let end = bytes.count - 22
            let central = bytes.value32(at: end + 16)
            var descriptor = signed ? Data([0x50, 0x4B, 0x07, 0x08]) : Data()
            descriptor.append(bytes[14..<26])
            bytes.set32(central + descriptor.count, at: end + 16)
            bytes.insert(contentsOf: descriptor, at: central)
            XCTAssertEqual(try inspect(bytes).entries["mimetype"], Data("safe".utf8))
        }
    }

    private func archive(_ text: String) throws -> Data {
        try ZIPFixtureBuilder.archive(entries: [.init(name: "mimetype", content: Data(text.utf8), isStored: true)])
    }
    private func write(_ bytes: Data, name: String = "source.zip") throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    private func inspect(_ bytes: Data) throws -> ZIPPackageContents {
        try ZIPArchiveInspector.packageContents(at: write(bytes), entryNames: ["mimetype"])
    }
}

private extension Data {
    mutating func set16(_ value: Int, at offset: Int) {
        replaceSubrange(offset..<(offset + 2), with: (0..<2).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    mutating func set32(_ value: Int, at offset: Int) {
        replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    func value32(at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(self[offset + $1]) << ($1 * 8) }
    }
}
