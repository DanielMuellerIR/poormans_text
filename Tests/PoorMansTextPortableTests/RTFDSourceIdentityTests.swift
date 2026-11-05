import Foundation
import XCTest
@testable import PoorMansTextCore

final class RTFDSourceIdentityTests: XCTestCase {
    private let original = Data(#"{\rtf1\ansi ORIGINALTEXT \u945? AFTERTEXT}"#.utf8)
    private let expectedHash = "55af1a36037904fd5c1c7d49aa17b7b0ed7f150e5bfe94888b73f33ba48aeb3a"

    func testConversionReportsOriginalTextBeforeRichTextRewriting() throws {
        try withPackage { root, package, text in
            let result = try DocumentConverter().convert(.init(inputURL: package,
                destination: .directory(root.appendingPathComponent("result")),
                options: .init(conversionReport: true)))
            let identity = try XCTUnwrap(result.sourceIdentity)
            XCTAssertEqual(identity.memberPath, "TXT.rtf")
            XCTAssertEqual(identity.sha256, expectedHash)
            XCTAssertEqual(identity.byteCount, original.count)
            XCTAssertNil(identity.unavailableReason)
            XCTAssertTrue(try identity.matchesFile(at: package))
            XCTAssertEqual(try Data(contentsOf: text), original)
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertTrue(markdown.contains("ORIGINALTEXT"))
            XCTAssertTrue(markdown.contains("α"))
            XCTAssertTrue(markdown.contains("AFTERTEXT"))
            let report = try JSONDecoder().decode(ConversionReport.self,
                from: Data(contentsOf: XCTUnwrap(result.reportFile)))
            XCTAssertEqual(report.source, identity)
            try Data("changed original text".utf8).write(to: text)
            XCTAssertFalse(try identity.matchesFile(at: package))
        }
    }

    func testMemberHashDoesNotClaimToBindPackageAttachments() throws {
        try withPackage { _, package, _ in
            let identity = try decodedIdentity(member: "TXT.rtf")
            let attachment = package.appendingPathComponent("unreferenced.txt")
            try Data("first attachment".utf8).write(to: attachment)
            XCTAssertTrue(try identity.matchesFile(at: package))
            try Data("changed attachment".utf8).write(to: attachment)
            XCTAssertTrue(try identity.matchesFile(at: package))
        }
    }

    func testLinkAndUnknownMemberCannotEscapeThePackage() throws {
        try withPackage { root, package, text in
            let identity = try decodedIdentity(member: "TXT.rtf")
            let outside = root.appendingPathComponent("outside.rtf")
            try original.write(to: outside)
            try FileManager.default.removeItem(at: text)
            try FileManager.default.createSymbolicLink(at: text, withDestinationURL: outside)
            XCTAssertThrowsError(try identity.matchesFile(at: package))
            XCTAssertFalse(try decodedIdentity(member: "../outside.rtf").matchesFile(at: package))
        }
    }

    private func decodedIdentity(member: String) throws -> ConversionSourceIdentity {
        let data = try JSONSerialization.data(withJSONObject: ["name": "Original.rtfd",
            "memberPath": member, "sha256": expectedHash, "byteCount": original.count])
        return try JSONDecoder().decode(ConversionSourceIdentity.self, from: data)
    }

    private func withPackage(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMT-RTFD-Identity-\(UUID())")
        let package = root.appendingPathComponent("Original.rtfd")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = package.appendingPathComponent("TXT.rtf")
        try original.write(to: text)
        try body(root, package, text)
    }
}
