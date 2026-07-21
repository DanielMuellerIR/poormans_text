import AppKit
import Foundation
import XCTest
@testable import PoorMansTextAppSupport

final class AppModelDropTests: XCTestCase {
    @MainActor
    func testFileURLItemProviderRunsRealConversion() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            let fixture = try FixtureFactory.createRichRTFD(in: temporaryDirectory)
            try await assertDropConverts(fixture.packageURL, expectedAssetCount: 2)
        }
    }

    @MainActor
    func testFileURLItemProviderRunsRealRTFConversion() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            let fixture = try FixtureFactory.createRichRTF(in: temporaryDirectory)
            try await assertDropConverts(fixture.fileURL, expectedAssetCount: 1)
        }
    }

    @MainActor
    private func assertDropConverts(_ inputURL: URL, expectedAssetCount: Int) async throws {
        let pandocCandidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]
        try XCTSkipUnless(
            pandocCandidates.contains(where: FileManager.default.isExecutableFile),
            "Pandoc is required for the app drop integration tests."
        )
        let provider = NSItemProvider(object: inputURL as NSURL)
        let model = AppModel()

        XCTAssertTrue(model.acceptDrop([provider]))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            switch model.state {
            case .succeeded(let result):
                XCTAssertTrue(FileManager.default.fileExists(atPath: result.markdownFile.path))
                XCTAssertEqual(result.assets.count, expectedAssetCount)
                return
            case .failed(_, let message):
                return XCTFail("Drop conversion failed: \(message)")
            case .idle, .converting:
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        XCTFail("Drop conversion did not finish within five seconds.")
    }

    @MainActor
    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
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
        try await body(temporaryDirectory)
    }
}
