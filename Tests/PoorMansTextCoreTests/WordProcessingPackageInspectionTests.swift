import Foundation
import XCTest
@testable import PoorMansTextCore

/// XML kennt keine festen Präfixe: `w:ins` und `x:ins` meinen dasselbe Element,
/// solange beide auf denselben Namensraum zeigen. Diese Tests halten fest, dass
/// die Paketprüfung Elemente über ihren Namen erkennt und nicht über den Text,
/// mit dem ein Erzeuger sie zufällig geschrieben hat.
final class WordProcessingPackageInspectionTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextPackageInspectionTests-\(UUID().uuidString)",
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

    func testFieldCodesAreNotReportedAsTrackedChanges() throws {
        // `<w:instrText>` ist ein gewöhnlicher Feldcode, etwa für ein
        // Inhaltsverzeichnis — und beginnt zufällig mit `<w:ins`.
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:instrText>TOC \\o "1-3"</w:instrText></w:r></w:p></w:body>
        </w:document>
        """
        let url = try write(
            try ZIPFixtureBuilder.docxPackage(documentXML: documentXML),
            as: "Fields.docx"
        )

        let inspection = try DocumentConverter().inspect(url)
        XCTAssertEqual(inspection.format, .docx)
        XCTAssertEqual(inspection.expectedWarnings, [])
    }

    func testTrackedChangesAndCommentsAreFoundWithAnUnusualPrefix() throws {
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:document xmlns:x="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <x:body><x:p>
        <x:commentRangeStart x:id="1"/>
        <x:ins x:id="2"><x:r><x:t>Accepted change</x:t></x:r></x:ins>
        </x:p></x:body>
        </x:document>
        """
        let url = try write(
            try ZIPFixtureBuilder.docxPackage(documentXML: documentXML),
            as: "Prefixed.docx"
        )

        let inspection = try DocumentConverter().inspect(url)
        XCTAssertEqual(
            inspection.expectedWarnings.map(\.code),
            [
                "wordProcessing.commentsNotPreserved",
                "wordProcessing.changesAccepted",
            ]
        )
    }

    func testExternalImageRelationshipIsFoundWithAnUnusualPrefix() throws {
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>Text</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let relationshipsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <r:Relationships xmlns:r="http://schemas.openxmlformats.org/package/2006/relationships">
        <r:Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" \
        Target="https://example.com/remote.png" TargetMode="External"/>
        </r:Relationships>
        """
        let url = try write(
            try ZIPFixtureBuilder.docxPackage(
                documentXML: documentXML,
                relationshipsXML: relationshipsXML
            ),
            as: "RemoteImage.docx"
        )
        let outputURL = temporaryDirectory.appendingPathComponent("remote-result", isDirectory: true)

        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(inputURL: url, destination: .directory(outputURL))
            )
        ) { error in
            guard case ConversionError.unsafeImageReference(let reference) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reference, "https://example.com/remote.png")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testODTAnnotationsChangesAndExternalImagesAreFoundWithUnusualPrefixes() throws {
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <o:document-content \
        xmlns:o="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:t="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
        xmlns:dr="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" \
        xmlns:xl="http://www.w3.org/1999/xlink">
        <o:body><o:text>
        <t:tracked-changes/>
        <t:p><o:annotation><t:p>Note</t:p></o:annotation>Annotated ODT text</t:p>
        <t:p><dr:frame><dr:image xl:href="https://example.com/remote.png"/></dr:frame></t:p>
        </o:text></o:body>
        </o:document-content>
        """
        let url = try write(
            try ZIPFixtureBuilder.odtPackage(contentXML: contentXML),
            as: "Prefixed.odt"
        )

        let inspection = try DocumentConverter().inspect(url)
        XCTAssertEqual(inspection.format, .odt)
        XCTAssertEqual(
            inspection.expectedWarnings.map(\.code),
            [
                "wordProcessing.commentsNotPreserved",
                "openDocument.changesNotPreserved",
            ]
        )

        let outputURL = temporaryDirectory.appendingPathComponent("odt-result", isDirectory: true)
        XCTAssertThrowsError(
            try DocumentConverter().convert(
                ConversionRequest(inputURL: url, destination: .directory(outputURL))
            )
        ) { error in
            guard case ConversionError.unsafeImageReference(let reference) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reference, "https://example.com/remote.png")
        }
    }

    private func write(_ archive: Data, as name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try archive.write(to: url)
        return url
    }
}
