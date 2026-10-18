import Foundation
import XCTest
@testable import PoorMansTextCore

final class ProfileStoreEditingTests: XCTestCase {
    func testExplicitEditingChecksExpectedRevisionAndPreservesLocalAndBoundValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileEdit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversionProfileStore(directory: root)
        let original = try ConversionProfile(name: "Original", outputDirectory: root.appendingPathComponent("output"), allowLocalTargets: true)
        try store.save(original, allowLocalTargets: true)
        var updated = original; updated.options.frontmatter = true
        XCTAssertThrowsError(try store.update(updated, replacing: original))
        try store.update(updated, replacing: original, allowLocalTargets: true)
        XCTAssertEqual(try store.load(named: "Original"), updated)
        XCTAssertThrowsError(try store.update(original, replacing: original, allowLocalTargets: true))
        XCTAssertThrowsError(try store.delete(original))
        XCTAssertEqual(try store.load(named: "Original"), updated)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.delete(updated); XCTAssertEqual(try store.profiles(), [])
    }
    func testConcurrentEditorsCannotReplaceEachOthersNewRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileEditRace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversionProfileStore(directory: root), original = try ConversionProfile(name: "Race")
        try store.save(original)
        let outcomes = Outcomes()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            var updated = original
            if index == 0 { updated.options.frontmatter = true } else { updated.options.docxChangeMode = .mark }
            do { try store.update(updated, replacing: original); outcomes.append(true) }
            catch { outcomes.append(false) }
        }
        XCTAssertEqual(outcomes.values.filter { $0 }.count, 1)
        let final = try store.load(named: "Race")
        XCTAssertNotEqual(final.options.frontmatter, final.options.docxChangeMode == .mark)
    }
    func testEditingNeverFollowsAReplacedProfileSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileEditLink-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversionProfileStore(directory: root), original = try ConversionProfile(name: "Link")
        try store.save(original)
        let leaf = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let external = root.appendingPathComponent("external"); let sentinel = try original.encoded()
        try sentinel.write(to: external); try FileManager.default.removeItem(at: leaf)
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: external)
        var updated = original; updated.options.frontmatter = true
        XCTAssertThrowsError(try store.update(updated, replacing: original)); XCTAssertThrowsError(try store.delete(original))
        XCTAssertEqual(try Data(contentsOf: external), sentinel)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: leaf.path), external.path)
    }
    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Bool] = []
        var values: [Bool] { lock.lock(); defer { lock.unlock() }; return stored }
        func append(_ value: Bool) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
    }
}
