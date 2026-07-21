import Foundation
import XCTest
@testable import PoorMansTextCore

final class DocumentConverterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextEngineTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testDetectsRTFAndRTFDFromTheirContents() throws {
        let rtfURL = try FixtureFactory.createMinimalRTF(
            in: temporaryDirectory,
            name: "Renamed document.data"
        )
        let rtfdURL = try FixtureFactory.createMinimalRTFD(
            in: temporaryDirectory,
            name: "Renamed package.data"
        )
        let immediateTextRTF = temporaryDirectory.appendingPathComponent("Immediate text.data")
        try Data(#"{\rtf1Text}"#.utf8).write(to: immediateTextRTF)
        let converter = DocumentConverter()

        XCTAssertEqual(converter.supportedFormats, [.rtf, .rtfd])
        XCTAssertEqual(try converter.detectFormat(at: rtfURL), .rtf)
        XCTAssertEqual(try converter.detectFormat(at: rtfdURL), .rtfd)
        XCTAssertEqual(try converter.detectFormat(at: immediateTextRTF), .rtf)
    }

    func testDoesNotTrustRichTextFilenameExtensions() throws {
        let falseRTF = temporaryDirectory.appendingPathComponent("False.rtf")
        try Data("plain text".utf8).write(to: falseRTF)
        let nearMiss = temporaryDirectory.appendingPathComponent("Near miss.data")
        try Data(#"{\rtfake plain text}"#.utf8).write(to: nearMiss)
        let falseRTFD = temporaryDirectory.appendingPathComponent("False.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: falseRTFD, withIntermediateDirectories: false)

        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: falseRTF)) { error in
            guard case ConversionError.invalidRichText = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: falseRTFD)) { error in
            guard case ConversionError.invalidRichText = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: nearMiss)) { error in
            guard case ConversionError.inputIsNotRichText = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testConvertsRealFixturesThroughFormatNeutralEngine() throws {
        try requirePandoc()
        let rtf = try FixtureFactory.createRichRTF(in: temporaryDirectory)
        let rtfd = try FixtureFactory.createRichRTFD(in: temporaryDirectory)
        let converter = DocumentConverter()

        let rtfResult = try converter.convert(
            ConversionRequest(
                inputURL: rtf.fileURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("RTF result"))
            )
        )
        let rtfdResult = try converter.convert(
            ConversionRequest(
                inputURL: rtfd.packageURL,
                destination: .directory(temporaryDirectory.appendingPathComponent("RTFD result"))
            )
        )

        XCTAssertEqual(rtfResult.format, .rtf)
        XCTAssertEqual(rtfdResult.format, .rtfd)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(rtfResult.assets.first)), rtf.imageData)
        XCTAssertEqual(
            Set(try rtfdResult.assets.map { try Data(contentsOf: $0) }),
            Set(rtfd.imageData)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: rtfResult.markdownFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rtfdResult.markdownFile.path))
    }

    func testTemporaryDestinationRemainsReadableAndReportsProgress() throws {
        try requirePandoc()
        let inputURL = try FixtureFactory.createMinimalRTF(in: temporaryDirectory)
        let progressRecorder = ProgressRecorder()

        let result = try DocumentConverter().convert(
            ConversionRequest(inputURL: inputURL, destination: .temporary),
            progress: { progressRecorder.append($0) }
        )
        defer {
            try? FileManager.default.removeItem(at: result.outputDirectory)
        }

        XCTAssertEqual(result.outputLifetime, .temporary)
        XCTAssertEqual(result.format, .rtf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.markdownFile.path))
        XCTAssertFalse(result.outputDirectory.path.hasPrefix(temporaryDirectory.path + "/"))
        let progressEvents = progressRecorder.events
        XCTAssertEqual(
            progressEvents.map(\.phase),
            [.detectingInput, .preparingOutput, .converting, .publishing, .finished]
        )
        XCTAssertNil(progressEvents.first?.format)
        XCTAssertEqual(progressEvents.dropFirst().compactMap(\.format), [.rtf, .rtf, .rtf, .rtf])
    }

    func testDoesNotOverwriteTargetCreatedWhileConversionRuns() throws {
        try requirePandoc()
        let inputURL = try FixtureFactory.createMinimalRTF(in: temporaryDirectory)
        let sourceBefore = try Data(contentsOf: inputURL)
        let outputURL = temporaryDirectory.appendingPathComponent("Late collision", isDirectory: true)
        let markerURL = outputURL.appendingPathComponent("keep.txt")

        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(inputURL: inputURL, destination: .directory(outputURL)),
                progress: { event in
                    guard event.phase == .publishing else {
                        return
                    }
                    try? FileManager.default.createDirectory(
                        at: outputURL,
                        withIntermediateDirectories: false
                    )
                    try? Data("keep".utf8).write(to: markerURL)
                }
            )
        ) { error in
            guard case ConversionError.outputAlreadyExists = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: inputURL), sourceBefore)
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "keep")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix(".poormans-text-") }
        XCTAssertTrue(leftovers.isEmpty, "Temporary conversion directories remain: \(leftovers)")
    }

    func testExplicitDestinationKeepsCollisionAndSourceSafety() throws {
        let inputURL = try FixtureFactory.createMinimalRTFD(in: temporaryDirectory)
        let existingOutput = temporaryDirectory.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingOutput, withIntermediateDirectories: false)
        let markerURL = existingOutput.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: markerURL)

        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(inputURL: inputURL, destination: .directory(existingOutput))
            )
        ) { error in
            guard case ConversionError.outputAlreadyExists = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "keep")

        let nestedOutput = inputURL.appendingPathComponent("Converted", isDirectory: true)
        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(inputURL: inputURL, destination: .directory(nestedOutput))
            )
        ) { error in
            guard case ConversionError.outputInsideInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInspectionDescribesKnownRTFColorLoss() throws {
        let inputURL = try FixtureFactory.createHighlightedRTF(in: temporaryDirectory)

        let inspection = try DocumentConverter().inspect(inputURL)

        XCTAssertEqual(inspection.format, .rtf)
        XCTAssertEqual(inspection.expectedWarnings.map(\.code), ["richText.colorNotPreserved"])
    }

    private func requirePandoc() throws {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]
        try XCTSkipUnless(
            candidates.contains(where: FileManager.default.isExecutableFile),
            "Pandoc is required for the format-neutral integration tests."
        )
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedEvents = [ConversionProgress]()

        var events: [ConversionProgress] {
            lock.withLock { storedEvents }
        }

        func append(_ event: ConversionProgress) {
            lock.withLock {
                storedEvents.append(event)
            }
        }
    }
}
