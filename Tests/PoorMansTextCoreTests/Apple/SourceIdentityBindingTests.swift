import Foundation
import XCTest
@testable import PoorMansTextCore

final class SourceIdentityBindingTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PMTBinding-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testPDFSelectionVerifiesImportedBytesWithoutMappingOrReport() throws {
        let input = try PDFSelectionFixture.create(in: root, texts: ["FirstMarker", "SecondMarker", "ThirdMarker"])
        let original = try Data(contentsOf: input), summary = try DocumentConverter().inspectPDFContents(input)
        let result = try DocumentConverter().convert(.init(inputURL: input, options: .init(pdfTextRecognition: .disabled, pdfPages: IndexSelection("2")), expectedSourceIdentity: summary.sourceIdentity))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "SecondMarker").count - 1, 1)
        XCTAssertFalse(text.contains("FirstMarker")); XCTAssertFalse(text.contains("ThirdMarker"))
        XCTAssertTrue(result.sourceMappings.isEmpty); XCTAssertNil(result.reportFile)
        XCTAssertEqual(result.sourceIdentity?.sha256, summary.sourceIdentity.sha256)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testChangedSourceBetweenOverviewAndStagingPublishesNothing() throws {
        let input = try PDFSelectionFixture.create(in: root, texts: ["OriginalMarker", "SelectedMarker"])
        let summary = try DocumentConverter().inspectPDFContents(input)
        let replacementRoot = root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: false)
        let replacement = try PDFSelectionFixture.create(in: replacementRoot, texts: ["ChangedMarker", "WrongMarker"])
        let changed = try Data(contentsOf: replacement)
        let destination = root.appendingPathComponent("result")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: input, destination: .directory(destination), options: .init(pdfPages: IndexSelection("2")), expectedSourceIdentity: summary.sourceIdentity), progress: { event in
            if event.phase == .converting && event.unit == nil { try! changed.write(to: input, options: .atomic) }
        })) { XCTAssertTrue($0.localizedDescription.contains("Read the content overview again"), $0.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: input), changed)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".poormans-text-") })
    }

    func testSymlinkRetargetCannotApplySelectionToDifferentBytes() throws {
        let input = root.appendingPathComponent("input.csv"), other = root.appendingPathComponent("other.csv"), link = root.appendingPathComponent("link.csv")
        try Data("name\nOriginalMarker\n".utf8).write(to: input)
        try Data("name\nOtherMarker\n".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        let fingerprint = try ConversionFileFingerprint.read(input)
        let expected = ConversionSourceIdentity(name: "input.csv", sha256: fingerprint.sha256, byteCount: fingerprint.byteCount, unavailableReason: nil)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        let output = root.appendingPathComponent("output")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: link, destination: .directory(output), expectedSourceIdentity: expected)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), "name\nOriginalMarker\n")
    }

    func testPublicationChecksImportedStreamInsteadOfReopeningAReplacedPath() throws {
        let input = root.appendingPathComponent("input.csv")
        let original = Data("name\nOriginalMarker\n".utf8), changed = Data("name\nChangedMarker\n".utf8)
        try original.write(to: input)
        let hash = try ConversionFileFingerprint.read(input)
        let identity = ConversionSourceIdentity(name: "input.csv", sha256: hash.sha256, byteCount: hash.byteCount, unavailableReason: nil)
        let result = try DocumentConverter().convert(.init(inputURL: input, expectedSourceIdentity: identity), progress: { event in
            if event.phase == .publishing { try! changed.write(to: input, options: .atomic) }
        })
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertTrue(text.contains("OriginalMarker")); XCTAssertFalse(text.contains("ChangedMarker"))
        XCTAssertEqual(result.sourceIdentity?.sha256, identity.sha256)
        XCTAssertEqual(try Data(contentsOf: input), changed)
    }

    func testUnavailableIdentityIsMandatoryAndCancellationBeforePublicationIsRespected() throws {
        let input = root.appendingPathComponent("input.csv")
        try Data("name\nOriginalMarker\n".utf8).write(to: input)
        let output = root.appendingPathComponent("output")
        let unknown = ConversionSourceIdentity(name: "input.csv", sha256: nil, byteCount: nil, unavailableReason: "unavailable")
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: input, destination: .directory(output), expectedSourceIdentity: unknown)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let hash = try ConversionFileFingerprint.read(input)
        let identity = ConversionSourceIdentity(name: "input.csv", sha256: hash.sha256, byteCount: hash.byteCount, unavailableReason: nil)
        let cancellation = ConversionCancellationToken()
        XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: input, destination: .directory(output), expectedSourceIdentity: identity), progress: { event in
            if event.phase == .publishing { cancellation.cancel() }
        }, cancellation: cancellation)) { guard case ConversionError.cancelled = $0 else { return XCTFail("Unexpected \($0)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testEPUBIdentityUsesCompleteVerifiedArchiveBeforeSelection() throws {
        let input = try EPUBSelectionFixture.create(in: root)
        let identity = try DocumentConverter().inspectEPUBContents(input).sourceIdentity
        let result = try DocumentConverter().convert(.init(inputURL: input, options: .init(epubChapters: IndexSelection("2")), expectedSourceIdentity: identity))
        let text = try String(contentsOf: result.markdownFile, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "AlphaMarker").count - 1, 1)
        XCTAssertFalse(text.contains("BetaMarker")); XCTAssertFalse(text.contains("GammaMarker"))
        XCTAssertEqual(result.sourceIdentity?.sha256, identity.sha256)
    }
}
