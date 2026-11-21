import Foundation
import XCTest

final class CLIStreamTests: XCTestCase {
    func testStandardOutputReportsClosedPipeAndRemovesTemporaryResult() throws {
        let files = FileManager.default
        let temp = files.temporaryDirectory
        let stem = "PipeProbe-\(UUID().uuidString)"
        let sourceDirectory = temp.appendingPathComponent(stem, isDirectory: true)
        try files.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: sourceDirectory) }

        let source = sourceDirectory.appendingPathComponent("\(stem).csv")
        let csv = Data("Name,Value\nPipe output,42\n".utf8)
        try csv.write(to: source)
        let arguments = ["--stdout", source.path]

        let normal = try runCLI(arguments)
        XCTAssertEqual(normal.status, 0, normal.diagnostic)
        XCTAssertEqual(normal.output, """
            # \(stem)

            ## Sheet: \(stem)

            | Name | Value |
            | --- | --- |
            | Pipe output | 42 |

            """)

        let closed = try runCLI(arguments, closeReader: true)
        XCTAssertEqual(closed.reason, .exit)
        XCTAssertEqual(closed.status, 74, closed.diagnostic)
        XCTAssertTrue(closed.diagnostic.contains("Cannot write standard output"), closed.diagnostic)
        XCTAssertEqual(try Data(contentsOf: source), csv)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: sourceDirectory.path), [source.lastPathComponent])

        let leftovers = try files.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.hasPrefix("PoorMansTextImport-")
                && files.fileExists(atPath: $0.appendingPathComponent("\(stem).md").path)
        }
        XCTAssertTrue(leftovers.isEmpty, "Temporäre Ausgabe blieb liegen: \(leftovers)")
        for leftover in leftovers { try files.removeItem(at: leftover) }
    }

    private func runCLI(
        _ arguments: [String], closeReader: Bool = false
    ) throws -> (status: Int32, reason: Process.TerminationReason, output: String, diagnostic: String) {
        #if os(Linux)
        let products = try XCTUnwrap(Bundle.main.executableURL).deletingLastPathComponent()
        #else
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        #endif
        let process = Process()
        process.executableURL = products.appendingPathComponent("poormans-text")
        process.arguments = arguments
        let output = Pipe()
        let diagnostic = Pipe()
        process.standardError = diagnostic
        if closeReader {
            try output.fileHandleForReading.close()
            process.standardOutput = output.fileHandleForWriting
        } else {
            process.standardOutput = output
        }
        try process.run()
        if closeReader { try output.fileHandleForWriting.close() }
        let result = closeReader ? Data() : output.fileHandleForReading.readDataToEndOfFile()
        let errors = diagnostic.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            process.terminationReason,
            String(decoding: result, as: UTF8.self),
            String(decoding: errors, as: UTF8.self)
        )
    }
}
