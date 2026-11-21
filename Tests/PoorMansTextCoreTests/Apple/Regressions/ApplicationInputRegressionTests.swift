import AppKit
import Foundation
import XCTest
@testable import PoorMansTextCore
@testable import PoorMansTextAppSupport

final class ApplicationInputRegressionTests: XCTestCase {
    @MainActor
    func testADropReservesTheAppUntilItsFilesAreLoaded() async throws {
        let root = try makeRegressionDirectory()
        let inputURL = root.appendingPathComponent("Eins.csv")
        try Data("a,b\n1,2\n".utf8).write(to: inputURL)
        let model = AppModel(defaults: .isolatedForAppTest())
        model.imageTextRecognition = .disabled

        XCTAssertTrue(model.acceptDrop([NSItemProvider(object: inputURL as NSURL)]))
        // Noch vor dem ersten `await` ist die App belegt: Ein zweiter Drop
        // wird abgelehnt statt später stumm verworfen.
        XCTAssertFalse(model.acceptsNewDocuments)
        XCTAssertFalse(model.acceptDrop([NSItemProvider(object: inputURL as NSURL)]))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .succeeded(let result) = model.state {
                XCTAssertEqual(result.format, .csv)
                XCTAssertTrue(model.acceptsNewDocuments)
                return
            }
            if case .failed(_, let message) = model.state {
                return XCTFail(message)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The dropped file did not convert within five seconds.")
    }

    @MainActor func testBoundSelectionRejectsDirectoryReplacementBeforeConversionAndRetry() async throws {
        let root = try makeRegressionDirectory()
        for retry in [false, true] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let input = try PDFSelectionFixture.create(in: directory, texts: ["OriginalMarker", "SelectedMarker"])
            let original = try Data(contentsOf: input)
            let identity = try DocumentConverter().inspectPDFContents(input).sourceIdentity
            let output = directory.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let app = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            app.destinationFolder = output; app.pdfTextRecognition = .disabled
            if retry {
                let occupied = output.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-markdown")
                try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
                try Data("KeepExisting".utf8).write(to: occupied.appendingPathComponent("sentinel"))
                app.convertSelection(input, selection: .pdf(try IndexSelection("2")), identity: identity)
                try await wait(app)
                guard case .failed = app.state else { return XCTFail("Expected occupied output") }
                app.destinationOverrides[input.path] = output.appendingPathComponent("retry-result")
            }
            let archived = directory.appendingPathComponent("original.pdf")
            try FileManager.default.moveItem(at: input, to: archived)
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
            let child = input.appendingPathComponent("child.csv"), childBytes = Data("name\nUnexpectedChildMarker\n".utf8)
            try childBytes.write(to: child)
            if retry { app.retryFailed() }
            else { app.convertSelection(input, selection: .pdf(try IndexSelection("2")), identity: identity) }
            try await wait(app)
            guard case .failed = app.state else { XCTFail("Changed selection became a folder import; retry=\(retry)"); continue }
            let outputs = try FileManager.default.contentsOfDirectory(atPath: output.path)
            XCTAssertEqual(outputs.count, retry ? 1 : 0, "\(outputs)")
            XCTAssertFalse(outputs.contains("child-markdown")); XCTAssertFalse(outputs.contains("retry-result"))
            if retry { XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-markdown/sentinel")), Data("KeepExisting".utf8)) }
            XCTAssertEqual(try Data(contentsOf: child), childBytes)
            XCTAssertEqual(try Data(contentsOf: archived), original)
            app.convert(input)
            try await wait(app)
            let complete = try String(contentsOf: output.appendingPathComponent("child-markdown/child.md"), encoding: .utf8)
            XCTAssertEqual(complete.components(separatedBy: "UnexpectedChildMarker").count - 1, 1)
        }
    }

    @MainActor private func wait(_ app: AppModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while app.isConverting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(app.isConverting)
    }
}
