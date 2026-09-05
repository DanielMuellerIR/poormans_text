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
    func testFileURLItemProviderRunsRealDOCXConversion() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            let inputURL = temporaryDirectory.appendingPathComponent("Dropped.docx")
            try FileManager.default.copyItem(
                at: wordProcessingFixture("pandoc.docx"),
                to: inputURL
            )
            try await assertDropConverts(inputURL, expectedAssetCount: 1)
        }
    }

    @MainActor
    func testUnsupportedInputUsesCoreValidation() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            let inputURL = temporaryDirectory.appendingPathComponent("Plain text.data")
            try Data("plain text".utf8).write(to: inputURL)
            let model = AppModel(defaults: .isolatedForAppTest())

            model.convert(inputURL)

            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                switch model.state {
                case .failed(let failedInput, let message):
                    XCTAssertEqual(failedInput, inputURL)
                    XCTAssertTrue(message.hasPrefix("Unsupported input format:"))
                    return
                case .succeeded:
                    return XCTFail("Unsupported input was converted.")
                case .idle, .converting, .convertingBatch, .batchFinished, .copiedToClipboard:
                    try await Task.sleep(for: .milliseconds(20))
                }
            }

            XCTFail("Core validation did not finish within two seconds.")
        }
    }

    @MainActor
    func testImageModeCanDisableOCRForARealAppConversion() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            let inputURL = temporaryDirectory.appendingPathComponent("Photo.png")
            try FileManager.default.copyItem(
                at: wordProcessingFixture("fixture.png"),
                to: inputURL
            )
            let model = AppModel(defaults: .isolatedForAppTest())
            model.imageTextRecognition = .disabled

            model.convert(inputURL)

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                switch model.state {
                case .succeeded(let result):
                    XCTAssertEqual(result.format.rawValue, "image")
                    XCTAssertTrue(result.diagnostics.isEmpty)
                    let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
                    XCTAssertFalse(markdown.contains("## OCR text"), markdown)
                    return
                case .failed(_, let message):
                    return XCTFail("Image conversion failed: \(message)")
                case .idle, .converting, .convertingBatch, .batchFinished, .copiedToClipboard:
                    try await Task.sleep(for: .milliseconds(50))
                }
            }

            XCTFail("Image conversion did not finish within five seconds.")
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
        let model = AppModel(defaults: .isolatedForAppTest())

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
            case .idle, .converting, .convertingBatch, .batchFinished, .copiedToClipboard:
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

    private func wordProcessingFixture(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/WordProcessing")
            .appendingPathComponent(name)
    }
}
