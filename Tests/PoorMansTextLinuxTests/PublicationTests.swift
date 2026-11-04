import Foundation
import XCTest
import Glibc
@testable import PoorMansTextCore

final class PublicationTests: XCTestCase {
    func testCSVBytesPublishWithoutChangingSourceAndCollision() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.csv")
        let original = Data("Name,Value\nÄpfel,12\nBirnen,7\n".utf8)
        try original.write(to: source)
        let publication = try LinuxOutputPublication(outputURL: root.appendingPathComponent("out"))
        let result = publication.temporaryRoot.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        try original.write(to: result.appendingPathComponent("source.csv"))
        try publication.publish()
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out/source.csv")), original)
        let collision = try LinuxOutputPublication(outputURL: root.appendingPathComponent("out"))
        try FileManager.default.createDirectory(at: collision.temporaryRoot.appendingPathComponent("result"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try collision.publish()) {
            guard case ConversionError.outputAlreadyExists = $0 else { return XCTFail("Wrong error: \($0)") }
        }
    }

    func testCSVConversionRetainsCompleteResultWhenOutputParentChangesBeforePublication() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.csv")
        let original = Data("Name,Value\nÄpfel,12\nBirnen,7\n".utf8)
        try original.write(to: source)
        let parent = root.appendingPathComponent("parent")
        let held = root.appendingPathComponent("held")
        let foreign = root.appendingPathComponent("foreign")
        for directory in [parent, foreign] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let sentinel = foreign.appendingPathComponent("sentinel")
        let sentinelBytes = Data("FOREIGN-UNCHANGED".utf8)
        try sentinelBytes.write(to: sentinel)
        let request = ConversionRequest(inputURL: source,
            destination: .directory(parent.appendingPathComponent("out")),
            options: .init(conversionReport: true))
        XCTAssertThrowsError(try DocumentConverter().convert(request, progress: { event in
            if event.phase == .publishing {
                do {
                    try FileManager.default.moveItem(at: parent, to: held)
                    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: foreign)
                } catch { XCTFail("Could not exchange the output parent: \(error)") }
            }
        })) { error in
            guard case ConversionError.fileSystemFailure(let message) = error,
                  message.contains("ESTALE") else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign.path), ["sentinel"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.appendingPathComponent("out").path))
        let stagingNames = try FileManager.default.contentsOfDirectory(atPath: held.path)
        XCTAssertEqual(stagingNames.count, 1)
        let stagingName = try XCTUnwrap(stagingNames.first)
        XCTAssertTrue(stagingName.hasPrefix(".poormans-text-"))
        let result = held.appendingPathComponent(stagingName).appendingPathComponent("result")
        let markdownBytes = try Data(contentsOf: result.appendingPathComponent("source.md"))
        let markdown = try XCTUnwrap(String(data: markdownBytes, encoding: .utf8))
        for row in ["| Name | Value |", "| Äpfel | 12 |", "| Birnen | 7 |"] {
            XCTAssertEqual(markdown.components(separatedBy: row).count - 1, 1)
        }
        let report = try JSONDecoder().decode(ConversionReport.self,
            from: Data(contentsOf: result.appendingPathComponent("conversion-report.json")))
        XCTAssertEqual(report.source.byteCount, original.count)
        XCTAssertEqual(report.source.sha256, ConversionFileFingerprint.digest(original))
        XCTAssertEqual(report.sourceMappings.count, 6)
        for mapping in report.sourceMappings { XCTAssertNotNil(mapping.output.text(in: markdownBytes)) }
    }

    func testParentExchangeAtAllPublicationBoundaries() throws {
        for phase in ["before", "between", "after"] {
            let root = try temporary()
            defer { try? FileManager.default.removeItem(at: root) }
            let parent = root.appendingPathComponent("parent")
            let held = root.appendingPathComponent("held")
            let foreign = root.appendingPathComponent("foreign")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
            try Data("sentinel".utf8).write(to: foreign.appendingPathComponent("sentinel"))
            let publication = try LinuxOutputPublication(outputURL: parent.appendingPathComponent("out"))
            let staged = publication.temporaryRoot.appendingPathComponent("result")
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
            try Data("complete".utf8).write(to: staged.appendingPathComponent("content.md"))
            func swap() throws {
                try FileManager.default.moveItem(at: parent, to: held)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: foreign)
            }
            if phase == "before" { try swap() }
            XCTAssertThrowsError(try publication.publish(beforeRename: { if phase == "between" { try swap() } }, afterRename: { if phase == "after" { try swap() } })) {
                guard case ConversionError.fileSystemFailure(let detail) = $0, detail.contains("ESTALE") else { return XCTFail("Wrong error: \($0)") }
            }
            publication.cleanup()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign.path), ["sentinel"])
            let retained = phase == "before" ? staged : held.appendingPathComponent("out")
            XCTAssertEqual(try String(contentsOf: retained.appendingPathComponent("content.md"), encoding: .utf8), "complete")
        }
    }

    func testCleanupRejectsReplacedStagingAndDoesNotFollowSymlinks() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data("safe".utf8).write(to: foreign.appendingPathComponent("sentinel"))
        let publication = try LinuxOutputPublication(outputURL: root.appendingPathComponent("out"))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let stage = root.appendingPathComponent(names.first { $0.hasPrefix(".poormans-text-") }!)
        let relocated = root.appendingPathComponent("relocated")
        try FileManager.default.moveItem(at: stage, to: relocated)
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: foreign)
        publication.cleanup()
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("sentinel")), Data("safe".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
    }

    func testCleanupAfterParentExchangeUsesHeldDirectory() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let held = root.appendingPathComponent("held")
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data("safe".utf8).write(to: foreign.appendingPathComponent("sentinel"))
        let publication = try LinuxOutputPublication(outputURL: parent.appendingPathComponent("out"))
        let nested = publication.temporaryRoot.appendingPathComponent("work/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("link"), withDestinationURL: foreign)
        try FileManager.default.moveItem(at: parent, to: held)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: foreign)
        publication.cleanup()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: held.path).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign.path), ["sentinel"])
    }

    func testParentSymlinkRejectedBeforeStagingCreation() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertThrowsError(try LinuxOutputPublication(outputURL: alias.appendingPathComponent("out")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }

    func testSixtyFourPublishersNeverReplace() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let counts = Counts()
        DispatchQueue.concurrentPerform(iterations: 64) { n in
            do {
                let publication = try LinuxOutputPublication(outputURL: root.appendingPathComponent("out"))
                let stage = publication.temporaryRoot.appendingPathComponent("result")
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                try Data("\(n)".utf8).write(to: stage.appendingPathComponent("winner"))
                try publication.publish()
                counts.add(success: true)
            } catch ConversionError.outputAlreadyExists { counts.add(success: false) }
            catch { counts.fail(String(describing: error)) }
        }
        XCTAssertEqual(counts.success, 1)
        XCTAssertEqual(counts.collisions, 63)
        XCTAssertTrue(counts.errors.isEmpty, "\(counts.errors)")
        XCTAssertNotNil(Int(try String(contentsOf: root.appendingPathComponent("out/winner"), encoding: .utf8)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".poormans-text-") }.isEmpty)
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pmt-publication-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
private final class Counts: @unchecked Sendable {
    let lock = NSLock()
    var success = 0
    var collisions = 0
    var errors: [String] = []
    func add(success succeeded: Bool) { lock.lock(); defer { lock.unlock() }; if succeeded { success += 1 } else { collisions += 1 } }
    func fail(_ error: String) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
}
