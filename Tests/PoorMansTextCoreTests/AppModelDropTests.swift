import AppKit
import Foundation
import XCTest
@testable import PoorMansTextAppSupport

final class AppModelDropTests: XCTestCase {
    @MainActor
    func testFileURLItemProviderRunsRealConversion() async throws {
        let pandocCandidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]
        try XCTSkipUnless(
            pandocCandidates.contains(where: FileManager.default.isExecutableFile),
            "Pandoc is required for the app drop integration test."
        )

        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextDropTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let fixture = try FixtureFactory.createRichRTFD(in: temporaryDirectory)
        let provider = NSItemProvider(object: fixture.packageURL as NSURL)
        let model = AppModel()

        XCTAssertTrue(model.acceptDrop([provider]))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            switch model.state {
            case .succeeded(let result):
                XCTAssertTrue(FileManager.default.fileExists(atPath: result.markdownFile.path))
                XCTAssertEqual(result.assets.count, 2)
                return
            case .failed(_, let message):
                return XCTFail("Drop conversion failed: \(message)")
            case .idle, .converting:
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        XCTFail("Drop conversion did not finish within five seconds.")
    }
}
