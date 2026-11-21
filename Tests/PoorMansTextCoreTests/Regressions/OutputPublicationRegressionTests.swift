import Foundation
import XCTest
@testable import PoorMansTextCore

final class OutputPublicationRegressionTests: XCTestCase {
    func testStagingIsPrivateUntilPublicationAndIsRemovedOnCancellation() throws {
        let root = try makeRegressionDirectory()
        let source = root.appendingPathComponent("private.csv")
        let bytes = Data("Name,Value\nCONFIDENTIAL,42\n".utf8)
        try bytes.write(to: source)
        for cancel in [false, true] {
            let token = ConversionCancellationToken()
            let observations = PermissionObservations()
            let target = root.appendingPathComponent(cancel ? "cancelled" : "complete")
            let convert = {
                try DocumentConverter().convert(ConversionRequest(inputURL: source, destination: .directory(target)),
                    progress: { event in
                        guard event.phase == .converting || event.phase == .publishing else { return }
                        let stages = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                        for stage in stages where stage.lastPathComponent.hasPrefix(".poormans-text-") {
                            let attributes = try? FileManager.default.attributesOfItem(atPath: stage.path)
                            observations.append((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1)
                        }
                        if cancel, event.phase == .publishing { token.cancel() }
                    }, cancellation: token)
            }
            if cancel { XCTAssertThrowsError(try convert()) } else { _ = try convert() }
            XCTAssertGreaterThanOrEqual(observations.values.count, 2)
            XCTAssertEqual(Set(observations.values), [0o700])
            XCTAssertEqual(FileManager.default.fileExists(atPath: target.path), !cancel)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private final class PermissionObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int] = []
        func append(_ value: Int) { lock.withLock { storage.append(value) } }
        var values: [Int] { lock.withLock { storage } }
    }
}
