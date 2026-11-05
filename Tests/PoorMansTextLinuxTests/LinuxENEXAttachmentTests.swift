#if os(Linux)
import Foundation
import XCTest
@testable import PoorMansTextCore

final class LinuxENEXAttachmentTests: XCTestCase {
    func testPDFDeclarationRejectsOtherBytesBeforeStartingBackend() {
        XCTAssertThrowsError(try LinuxPDFAttachment.validate(Data("not a PDF".utf8))) {
            XCTAssertTrue($0 is ImportFailure, "\($0)")
        }
    }

    func testMissingPDFBackendSurvivesENEXErrorBoundary() throws {
        guard LinuxPDFAdapter().unavailableReason(for: .pdf) != nil else {
            throw XCTSkip("Requires the isolated missing-Poppler environment")
        }
        try withPDFResource { source, output, bytes in
            XCTAssertThrowsError(try DocumentConverter().convert(.init(inputURL: source, destination: .directory(output)))) {
                XCTAssertTrue($0 is PlatformBackendUnavailable, "\($0)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testValidatedPDFIsRetainedWithoutChangingBytes() throws {
        guard LinuxPDFAdapter().unavailableReason(for: .pdf) == nil else {
            throw XCTSkip("Requires the local Poppler backend")
        }
        try withPDFResource { source, output, bytes in
            let result = try DocumentConverter().convert(.init(inputURL: source, destination: .directory(output)))
            let attachments = result.assets.filter { $0.pathExtension == "pdf" }
            XCTAssertEqual(attachments.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(attachments.first)), try Data(contentsOf: pdfFixture))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            let text = try String(contentsOf: XCTUnwrap(result.documents.first).markdownFile, encoding: .utf8)
            XCTAssertTrue(text.contains("PDF_ATTACHMENT_BODY"))
            XCTAssertTrue(text.contains("resource-000001.pdf"))
        }
    }

    private var pdfFixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PoorMansTextCoreTests/Fixtures/LinuxPDF/word-gaps.pdf")
    }

    private func withPDFResource(_ body: (URL, URL, Data) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PMT-ENEX-PDF-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = try Data(contentsOf: pdfFixture)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <en-export><note><title>PDF attachment</title><content><![CDATA[<en-note>PDF_ATTACHMENT_BODY</en-note>]]></content>
        <resource><data encoding="base64">\(pdf.base64EncodedString())</data><mime>application/pdf</mime>
        <resource-attributes><file-name>reference.pdf</file-name></resource-attributes></resource></note></en-export>
        """
        let bytes = Data(xml.utf8)
        let source = root.appendingPathComponent("source.enex")
        try bytes.write(to: source, options: .withoutOverwriting)
        try body(source, root.appendingPathComponent("result"), bytes)
    }
}
#endif
