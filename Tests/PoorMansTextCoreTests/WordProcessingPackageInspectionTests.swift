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

    func testMacroEnabledDocumentIsAcceptedWithExplicitMacroWarning() throws {
        let url = try write(
            try ZIPFixtureBuilder.docxPackage(
                documentXML: minimalDocumentXML,
                mainContentType: ZIPFixtureBuilder.docmMainContentType
            ),
            as: "Macro.docm"
        )

        let inspection = try DocumentConverter().inspect(url)

        XCTAssertEqual(inspection.format, .docx)
        XCTAssertEqual(
            inspection.expectedWarnings.map(\.code),
            ["wordProcessing.macrosNotPreserved"]
        )
    }

    func testTemplateIsAcceptedWithExplicitTemplateWarning() throws {
        let url = try write(
            try ZIPFixtureBuilder.docxPackage(
                documentXML: minimalDocumentXML,
                mainContentType: ZIPFixtureBuilder.dotxMainContentType
            ),
            as: "Template.dotx"
        )

        let inspection = try DocumentConverter().inspect(url)

        XCTAssertEqual(inspection.format, .docx)
        XCTAssertEqual(
            inspection.expectedWarnings.map(\.code),
            ["wordProcessing.templateSemanticsNotPreserved"]
        )
    }

    func testMacroEnabledTemplateReportsBothLosses() throws {
        let url = try write(
            try ZIPFixtureBuilder.docxPackage(
                documentXML: minimalDocumentXML,
                mainContentType: ZIPFixtureBuilder.dotmMainContentType
            ),
            as: "MacroTemplate.dotm"
        )

        let inspection = try DocumentConverter().inspect(url)

        XCTAssertEqual(inspection.format, .docx)
        XCTAssertEqual(
            inspection.expectedWarnings.map(\.code),
            [
                "wordProcessing.macrosNotPreserved",
                "wordProcessing.templateSemanticsNotPreserved",
            ]
        )
    }

    func testRejectsWordPackageWithAnUnrelatedMainContentType() throws {
        let url = try write(
            try ZIPFixtureBuilder.docxPackage(
                documentXML: minimalDocumentXML,
                mainContentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
            ),
            as: "NotWord.docx"
        )

        XCTAssertThrowsError(try DocumentConverter().inspect(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("content type"))
        }
    }

    func testForeignOverrideCannotReplaceTheWordMainContentType() throws {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"
          xmlns:foo="urn:example:foreign">
          <Override PartName="/word/document.xml"
            ContentType="\(ZIPFixtureBuilder.docxMainContentType)"/>
          <foo:Override PartName="/word/document.xml"
            ContentType="application/vnd.ms-word.document.macroEnabled.main+xml"/>
        </Types>
        """
        let url = try write(
            try ZIPFixtureBuilder.docxPackage(
                documentXML: minimalDocumentXML,
                contentTypesOverride: contentTypes
            ),
            as: "ForeignOverride.docx"
        )

        let inspection = try DocumentConverter().inspect(url)

        XCTAssertEqual(inspection.format, .docx)
        XCTAssertEqual(inspection.expectedWarnings, [])
    }

    func testForeignPrefixedAttributesCannotDefineTheWordMainContentType() throws {
        let invalidOverrides = [
            """
            <Override foo:PartName="/word/document.xml"
              ContentType="\(ZIPFixtureBuilder.docxMainContentType)"/>
            """,
            """
            <Override PartName="/word/document.xml"
              foo:ContentType="\(ZIPFixtureBuilder.docxMainContentType)"/>
            """,
        ]

        for (index, invalidOverride) in invalidOverrides.enumerated() {
            let contentTypes = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"
              xmlns:foo="urn:example:foreign">
              \(invalidOverride)
            </Types>
            """
            let url = try write(
                try ZIPFixtureBuilder.docxPackage(
                    documentXML: minimalDocumentXML,
                    contentTypesOverride: contentTypes
                ),
                as: "ForeignAttributes\(index).docx"
            )

            XCTAssertThrowsError(try DocumentConverter().inspect(url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("content type"))
            }
        }
    }

    func testRejectsWordPackageWhoseMainPartHasTheWrongRoot() throws {
        let wrongRoot = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>
        """
        let url = try write(
            try ZIPFixtureBuilder.docxPackage(documentXML: wrongRoot),
            as: "WrongRoot.docx"
        )

        XCTAssertThrowsError(try DocumentConverter().inspect(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("document root"))
        }
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

    // MARK: - Hauptteil laut OPC (Roadmap-Punkte 2026-09-10)

    /// Ein Paket, dessen Hauptteil nicht `word/document.xml` heißt; `_rels/.rels`
    /// zeigt darauf, wie es OPC vorsieht und Pandoc auflöst.
    private func renamedMainPartPackage(documentXML: String, target: String = "word/document2.xml",
                                        partName: String = "word/document2.xml") throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Override PartName="/\(partName)" ContentType="\(ZIPFixtureBuilder.docxMainContentType)"/>
        </Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="\(target)"/>
        </Relationships>
        """
        return try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(name: "[Content_Types].xml", content: Data(contentTypes.utf8)),
            ZIPFixtureBuilder.Entry(name: "_rels/.rels", content: Data(rootRelationships.utf8)),
            ZIPFixtureBuilder.Entry(name: partName, content: Data(documentXML.utf8)),
        ])
    }

    /// Der Hauptteil war fest auf `word/document.xml` verdrahtet; ein von Word
    /// repariertes Dokument mit `word/document2.xml` wurde abgelehnt, obwohl
    /// Pandoc es umwandelt.
    func testMainPartIsResolvedThroughTheOfficeDocumentRelationship() throws {
        let tracked = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:ins w:id="2"><w:r><w:t>Accepted change</w:t></w:r></w:ins></w:p></w:body>
        </w:document>
        """
        let url = try write(try renamedMainPartPackage(documentXML: tracked), as: "Repaired.docx")

        let inspection = try DocumentConverter().inspect(url)
        XCTAssertEqual(inspection.format, .docx)
        // Die Warnung beweist, dass wirklich `word/document2.xml` gelesen wurde.
        XCTAssertEqual(inspection.expectedWarnings.map(\.code), ["wordProcessing.changesAccepted"])

        // Ein führender Schrägstrich im Ziel ist laut OPC gleichwertig.
        let absolute = try write(
            try renamedMainPartPackage(documentXML: minimalDocumentXML, target: "/word/document2.xml"),
            as: "Absolute.docx"
        )
        XCTAssertEqual(try DocumentConverter().inspect(absolute).format, .docx)
    }

    func testARepairedDocumentConvertsLikePandocReadsIt() throws {
        guard ExternalToolResolver().isAvailable(.pandoc) else {
            throw XCTSkip("Pandoc is required for this conversion test.")
        }
        let url = try write(try renamedMainPartPackage(documentXML: minimalDocumentXML), as: "Repaired.docx")
        let outputURL = temporaryDirectory.appendingPathComponent("repaired-result", isDirectory: true)

        let result = try DocumentConverter().convert(
            ConversionRequest(inputURL: url, destination: .directory(outputURL))
        )

        XCTAssertTrue(try String(contentsOf: result.markdownFile, encoding: .utf8).contains("Fixture text"))
    }

    /// Zeigt `_rels/.rels` auf einen fehlenden Teil, ist das Paket kein
    /// lesbares Word-Dokument — nicht still `word/document.xml` nehmen.
    func testAMissingOfficeDocumentTargetIsRejected() throws {
        let url = try write(
            try renamedMainPartPackage(documentXML: minimalDocumentXML, target: "word/missing.xml"),
            as: "Dangling.docx"
        )

        XCTAssertThrowsError(try DocumentConverter().inspect(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("document-package entries are missing"), error.localizedDescription)
        }
    }

    /// Ein leerer `.rels`-Teil kann kein externes Bildziel verbergen und
    /// verwirft das Dokument nicht mehr; ein defekter bleibt ein Ablehnungsgrund.
    func testAnEmptyRelationshipsPartIsToleratedButABrokenOneIsNot() throws {
        // Der Builder deflatiert nicht leer; der leere Teil wird gespeichert.
        let empty = try write(
            try ZIPFixtureBuilder.archive(entries: [
                ZIPFixtureBuilder.Entry(
                    name: "[Content_Types].xml",
                    content: Data(ZIPFixtureBuilder.contentTypesXML(mainContentType: ZIPFixtureBuilder.docxMainContentType).utf8)
                ),
                ZIPFixtureBuilder.Entry(name: "word/document.xml", content: Data(minimalDocumentXML.utf8)),
                ZIPFixtureBuilder.Entry(name: "word/_rels/styles.xml.rels", content: Data(), isStored: true),
            ]),
            as: "EmptyRels.docx"
        )
        XCTAssertEqual(try DocumentConverter().inspect(empty).format, .docx)

        let broken = try write(
            try ZIPFixtureBuilder.docxPackage(
                documentXML: minimalDocumentXML, extraParts: ["word/_rels/styles.xml.rels": "<Relationships"]
            ),
            as: "BrokenRels.docx"
        )
        XCTAssertThrowsError(try DocumentConverter().inspect(broken))
    }

    /// Ein externes `draw:image` in `styles.xml` (Kopf-/Fußzeile) wurde nicht
    /// geprüft; nur `content.xml` zählte.
    func testODTExternalImageInStylesIsRejected() throws {
        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles \
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
        xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" \
        xmlns:xlink="http://www.w3.org/1999/xlink">
        <office:master-styles><style:master-page style:name="Standard">
        <style:header><draw:frame><draw:image xlink:href="https://example.com/header.png"/></draw:frame></style:header>
        </style:master-page></office:master-styles>
        </office:document-styles>
        """
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
        <office:body><office:text><text:p>Body text</text:p></office:text></office:body>
        </office:document-content>
        """
        let archive = try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(
                name: "mimetype", content: Data("application/vnd.oasis.opendocument.text".utf8), isStored: true
            ),
            ZIPFixtureBuilder.Entry(name: "content.xml", content: Data(contentXML.utf8)),
            ZIPFixtureBuilder.Entry(name: "styles.xml", content: Data(stylesXML.utf8)),
        ])
        let url = try write(archive, as: "HeaderImage.odt")
        let outputURL = temporaryDirectory.appendingPathComponent("odt-header-result", isDirectory: true)

        XCTAssertThrowsError(
            try DocumentConverter().convert(ConversionRequest(inputURL: url, destination: .directory(outputURL)))
        ) { error in
            guard case ConversionError.unsafeImageReference(let reference) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reference, "https://example.com/header.png")
        }
    }

    private func write(_ archive: Data, as name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try archive.write(to: url)
        return url
    }

    private var minimalDocumentXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>Fixture text</w:t></w:r></w:p></w:body>
        </w:document>
        """
    }
    // MARK: - Nachverfolgte Änderungen (Review-Funde 2026-09-10)

    private func inspectDOCX(document: String, extraParts: [String: String] = [:]) throws
        -> WordProcessingPackageInspection? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PMTTracked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Doc.docx")
        try ZIPFixtureBuilder.docxPackage(documentXML: document, extraParts: extraParts).write(to: url)
        return try WordProcessingPackageInspector.inspect(at: url)
    }

    private static let plainDocument = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:body><w:p><w:r><w:t>Text</w:t></w:r></w:p></w:body>
    </w:document>
    """

    /// Pandoc liest Fuß- und Endnoten mit und wendet `--track-changes=accept`
    /// auch dort an. Geprüft wurde bisher nur `word/document.xml`, also nahm die
    /// Umwandlung eine dort nachverfolgte Änderung still an.
    func testATrackedChangeOnlyInTheFootnotesIsStillReported() throws {
        let notes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:footnote w:id="1"><w:p><w:ins w:id="9" w:author="A"><w:r><w:t>neu</w:t></w:r></w:ins></w:p></w:footnote>
        </w:footnotes>
        """
        let inspection = try inspectDOCX(
            document: Self.plainDocument, extraParts: ["word/footnotes.xml": notes]
        )

        XCTAssertEqual(inspection?.containsTrackedChanges, true)
        XCTAssertTrue(inspection?.warnings.contains(.wordProcessingChangesAccepted) == true)
        // Ohne die Notiz bleibt es beim ungewarnten Dokument.
        XCTAssertEqual(try inspectDOCX(document: Self.plainDocument)?.containsTrackedChanges, false)
    }

    /// Wurde mit eingeschalteter Verfolgung nur formatiert, fehlte die Warnung
    /// ganz — `rPrChange` und Verwandte galten nicht als Änderung.
    func testAFormatOnlyTrackedChangeIsReported() throws {
        for element in ["rPrChange", "pPrChange", "tblPrChange", "cellMerge"] {
            let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body><w:p><w:pPr><w:\(element) w:id="3" w:author="A"/></w:pPr>
            <w:r><w:t>Text</w:t></w:r></w:p></w:body>
            </w:document>
            """
            XCTAssertEqual(
                try inspectDOCX(document: document)?.containsTrackedChanges, true, element
            )
        }
    }

}
