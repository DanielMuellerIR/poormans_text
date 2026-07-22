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
            guard case ConversionError.invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: falseRTFD)) { error in
            guard case ConversionError.invalidInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try DocumentConverter().detectFormat(at: nearMiss)) { error in
            guard case ConversionError.unsupportedInput = error else {
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

    func testRegisteredAdapterOwnsDetectionInspectionAndConversion() throws {
        let fixtureFormat = InputFormat(rawValue: "fixture")
        let inputURL = temporaryDirectory.appendingPathComponent("Sample.data")
        try Data("fixture document".utf8).write(to: inputURL)
        let adapter = SyntheticAdapter(
            format: fixtureFormat,
            marker: "fixture",
            priority: 40,
            warning: ConversionWarning(code: "fixture.loss", message: "Fixture warning")
        )
        let converter = DocumentConverter(adapters: [adapter])
        let outputURL = temporaryDirectory.appendingPathComponent("Fixture output")

        XCTAssertEqual(converter.supportedFormats, [fixtureFormat])
        XCTAssertEqual(try converter.detectFormat(at: inputURL), fixtureFormat)
        XCTAssertEqual(
            try converter.inspect(inputURL).expectedWarnings.map(\.code),
            ["fixture.loss"]
        )

        let result = try converter.convert(
            ConversionRequest(inputURL: inputURL, destination: .directory(outputURL))
        )
        XCTAssertEqual(result.format, fixtureFormat)
        XCTAssertEqual(
            try String(contentsOf: result.markdownFile, encoding: .utf8),
            "Converted fixture\n"
        )

        let encoded = try JSONEncoder().encode(fixtureFormat)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"fixture\"")
        XCTAssertEqual(try JSONDecoder().decode(InputFormat.self, from: encoded), fixtureFormat)
    }

    func testDetectorPriorityAndAmbiguityAreResolvedCentrally() throws {
        let inputURL = temporaryDirectory.appendingPathComponent("Shared.data")
        try Data("shared document".utf8).write(to: inputURL)
        let lowFormat = InputFormat(rawValue: "low")
        let highFormat = InputFormat(rawValue: "high")
        let peerFormat = InputFormat(rawValue: "peer")

        let prioritized = DocumentConverter(adapters: [
            SyntheticAdapter(format: lowFormat, marker: "shared", priority: 10),
            SyntheticAdapter(format: highFormat, marker: "shared", priority: 20),
        ])
        XCTAssertEqual(try prioritized.detectFormat(at: inputURL), highFormat)

        let ambiguous = DocumentConverter(adapters: [
            SyntheticAdapter(format: highFormat, marker: "shared", priority: 20),
            SyntheticAdapter(format: peerFormat, marker: "shared", priority: 20),
        ])
        XCTAssertThrowsError(try ambiguous.detectFormat(at: inputURL)) { error in
            guard case ConversionError.ambiguousInput(_, let formats) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(Set(formats), [highFormat, peerFormat])
        }
    }

    func testDetectorReportsGenericUnsupportedAndInvalidInput() throws {
        let fixtureFormat = InputFormat(rawValue: "fixture")
        let converter = DocumentConverter(adapters: [
            SyntheticAdapter(format: fixtureFormat, marker: "fixture", priority: 10),
        ])
        let unsupportedURL = temporaryDirectory.appendingPathComponent("Unsupported.data")
        try Data("other".utf8).write(to: unsupportedURL)
        XCTAssertThrowsError(try converter.detectFormat(at: unsupportedURL)) { error in
            guard case ConversionError.unsupportedInput = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let invalidURL = temporaryDirectory.appendingPathComponent("Invalid.data")
        try Data("invalid:fixture".utf8).write(to: invalidURL)
        XCTAssertThrowsError(try converter.detectFormat(at: invalidURL)) { error in
            guard case ConversionError.invalidInput(_, let format, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(format, fixtureFormat)
            XCTAssertEqual(reason, "fixture detector rejected the input")
        }
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

private struct SyntheticAdapter: DocumentConversionAdapter {
    let format: InputFormat
    let marker: String
    let priority: Int
    let warning: ConversionWarning?

    init(
        format: InputFormat,
        marker: String,
        priority: Int,
        warning: ConversionWarning? = nil
    ) {
        self.format = format
        self.marker = marker
        self.priority = priority
        self.warning = warning
    }

    var supportedFormats: Set<InputFormat> {
        [format]
    }

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let contents = try String(contentsOf: inputURL, encoding: .utf8)
        if contents.hasPrefix("invalid:\(marker)") {
            return .invalid(
                format: format,
                priority: priority,
                reason: "\(marker) detector rejected the input"
            )
        }
        guard contents.hasPrefix(marker) else {
            return .noMatch
        }
        return .match(
            AdapterInputInspection(
                format: format,
                priority: priority,
                expectedWarnings: warning.map { [$0] } ?? []
            )
        )
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        let markdownName = "Converted.md"
        try Data("Converted \(format.rawValue)\n".utf8).write(
            to: context.stagedOutputDirectory.appendingPathComponent(markdownName)
        )
        return StagedConversionResult(
            markdownRelativePath: markdownName,
            assetRelativePaths: [],
            warnings: warning.map { [$0] } ?? []
        )
    }
}
