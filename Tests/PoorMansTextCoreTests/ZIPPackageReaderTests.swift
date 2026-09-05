import Foundation
import XCTest
@testable import PoorMansTextCore

final class ZIPPackageReaderTests: XCTestCase {
    private var root: URL!
    private var work: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PackageReader-\(UUID())")
        work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testReaderRemainsBoundToThePrivateCopyAfterSourceAndLinkReplacement() throws {
        let first = root.appendingPathComponent("first.zip")
        let second = root.appendingPathComponent("second.zip")
        let link = root.appendingPathComponent("input.zip")
        let original = try ZIPFixtureBuilder.archive(entries: [
            .init(name: "a.xml", content: Data("first".utf8)),
            .init(name: "b.xml", content: Data("second entry".utf8)),
        ])
        try original.write(to: first)
        try ZIPFixtureBuilder.archive(entries: [.init(name: "a.xml", content: Data("replacement".utf8))]).write(to: second)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let reader = try ZIPArchiveInspector.openVerifiedPackage(from: link, into: work, named: "verified.zip")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        try Data("source is now truncated".utf8).write(to: first)
        XCTAssertEqual(reader.entryNames, Set(["a.xml", "b.xml"]))
        XCTAssertEqual(try reader.string(named: "a.xml"), "first")
        XCTAssertEqual(try reader.string(named: "b.xml"), "second entry")
        XCTAssertEqual(try reader.string(named: "a.xml"), "first")
        XCTAssertEqual(try Data(contentsOf: reader.url), original)
        XCTAssertNil(try reader.dataIfPresent(named: "absent.xml"))
        XCTAssertThrowsError(try reader.data(named: "absent.xml"))
    }

    func testOpeningVerifiesUnrequestedEntriesBeforeReturningAReader() throws {
        for (index, archive) in try [
            ZIPFixtureBuilder.wordProcessingPackage(declaredMediaChecksum: 0xDEADBEEF),
            ZIPFixtureBuilder.wordProcessingPackage(mediaContent: Data(repeating: 65, count: 1_048_576), declaredMediaSize: 32),
        ].enumerated() {
            let source = root.appendingPathComponent("bad-\(index).zip")
            try archive.write(to: source)
            XCTAssertThrowsError(try ZIPArchiveInspector.openVerifiedPackage(from: source, into: work, named: "bad-\(index).zip"))
            XCTAssertEqual(try Data(contentsOf: source), archive)
        }
    }

    func testTemporaryReaderRemovesItsCopyAfterSuccessfulAndThrowingBodies() throws {
        let source = root.appendingPathComponent("source.zip")
        let archive = try ZIPFixtureBuilder.wordProcessingPackage()
        try archive.write(to: source)
        let url = try ZIPArchiveInspector.withVerifiedReader(at: source) { reader in
            XCTAssertEqual(try WordProcessingPackageInspector.inspect(reader: reader)?.format, .docx)
            return reader.url
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        enum Expected: Error { case stop }
        var failedCopy: URL?
        XCTAssertThrowsError(try ZIPArchiveInspector.withVerifiedReader(at: source) { reader in
            failedCopy = reader.url
            throw Expected.stop
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(failedCopy).path))
        XCTAssertEqual(try Data(contentsOf: source), archive)
    }
}
