import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PoorMansTextCore

/// Die kleinen Formatgewinne der Roadmap-Etappe 4: makrofähige Excel-Mappen
/// und -Vorlagen, weitere Bildtypen. Beide laufen über vorhandene Adapter und
/// müssen deren Regeln (Warnungen, Asset-Namen, Formatkatalog) einhalten.
final class Stage4FormatTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PoorMansTextStage4Tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - XLSM, XLTX, XLTM

    func testMacroEnabledWorkbookAndTemplatesConvertLikeXLSXWithLossWarnings() throws {
        let cases: [(name: String, contentType: String, expected: [ConversionWarning])] = [
            ("Makros.xlsm", "application/vnd.ms-excel.sheet.macroEnabled.main+xml",
             [.spreadsheetMacrosNotPreserved]),
            ("Vorlage.xltx", "application/vnd.openxmlformats-officedocument.spreadsheetml.template.main+xml",
             [.spreadsheetTemplateSemanticsNotPreserved]),
            ("Beides.xltm", "application/vnd.ms-excel.template.macroEnabledTemplate.main+xml",
             [.spreadsheetMacrosNotPreserved, .spreadsheetTemplateSemanticsNotPreserved]),
        ]
        for testCase in cases {
            let sourceURL = root.appendingPathComponent(testCase.name)
            try xlsxLikePackage(mainContentType: testCase.contentType).write(to: sourceURL)

            let inspection = try DocumentConverter().inspect(sourceURL)
            XCTAssertEqual(inspection.format, .xlsx, testCase.name)
            for warning in testCase.expected {
                XCTAssertTrue(inspection.expectedWarnings.contains(warning), "\(testCase.name): \(warning.code)")
            }

            let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))
            XCTAssertEqual(result.format, .xlsx)
            for warning in testCase.expected {
                XCTAssertTrue(result.diagnostics.contains(warning), "\(testCase.name): \(warning.code)")
            }
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertTrue(markdown.contains("| Wert |"), markdown)
        }
    }

    func testAPlainXLSXStillCarriesNoMacroOrTemplateWarning() throws {
        let sourceURL = root.appendingPathComponent("Normal.xlsx")
        try xlsxLikePackage(
            mainContentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
        ).write(to: sourceURL)

        let result = try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))

        XCTAssertFalse(result.diagnostics.contains(.spreadsheetMacrosNotPreserved))
        XCTAssertFalse(result.diagnostics.contains(.spreadsheetTemplateSemanticsNotPreserved))
    }

    func testAnUnknownSpreadsheetContentTypeIsStillRejected() throws {
        let sourceURL = root.appendingPathComponent("Fremd.xlsm")
        try xlsxLikePackage(mainContentType: "application/vnd.example.unknown+xml").write(to: sourceURL)

        XCTAssertThrowsError(try DocumentConverter().convert(ConversionRequest(inputURL: sourceURL))) { error in
            guard case ConversionError.invalidInput(_, let format, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(format, .xlsx)
        }
    }

    func testTheFormatCatalogListsTheNewExtensions() {
        let xlsx = DocumentConverter().supportedFormatDescriptors.first { $0.format == .xlsx }
        XCTAssertEqual(xlsx?.fileExtensions, ["xlsx", "xlsm", "xltx", "xltm"])
        let image = DocumentConverter().supportedFormatDescriptors.first { $0.format == .image }
        XCTAssertEqual(image?.fileExtensions, ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "webp"])
    }

    // MARK: - GIF, BMP, WebP

    func testGIFBMPAndWebPAreKeptByteForByteAsAssets() throws {
        for (name, type) in [("Gif.gif", UTType.gif), ("Bmp.bmp", UTType.bmp), ("Webp.webp", UTType.webP)] {
            let sourceURL = root.appendingPathComponent(name)
            try createImage(type: type, at: sourceURL)

            let result = try DocumentConverter().convert(
                ConversionRequest(
                    inputURL: sourceURL,
                    options: ConversionOptions(imageTextRecognition: .disabled)
                )
            )

            XCTAssertEqual(result.format, .image, name)
            XCTAssertEqual(result.assets.map(\.lastPathComponent), ["image01.\(sourceURL.pathExtension)"], name)
            XCTAssertEqual(try Data(contentsOf: result.assets[0]), try Data(contentsOf: sourceURL), name)
            let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
            XCTAssertTrue(markdown.contains("](images/image01.\(sourceURL.pathExtension))"), markdown)
        }
    }

    func testANewImageTypeIsDetectedByContentEvenWithoutItsExtension() throws {
        let sourceURL = root.appendingPathComponent("ohne-endung")
        try createImage(type: UTType.webP, at: sourceURL)

        XCTAssertEqual(try DocumentConverter().detectFormat(at: sourceURL), .image)
    }

    // MARK: - Helfer

    /// Eine Ein-Blatt-Mappe mit frei wählbarem Hauptinhaltstyp.
    private func xlsxLikePackage(mainContentType: String) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="\(mainContentType)"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="Blatt1" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Wert</t></is></c></row></sheetData>
        </worksheet>
        """
        return try ZIPFixtureBuilder.archive(entries: [
            ZIPFixtureBuilder.Entry(name: "[Content_Types].xml", content: Data(contentTypes.utf8)),
            ZIPFixtureBuilder.Entry(name: "_rels/.rels", content: Data(rootRelationships.utf8)),
            ZIPFixtureBuilder.Entry(name: "xl/workbook.xml", content: Data(workbook.utf8)),
            ZIPFixtureBuilder.Entry(name: "xl/_rels/workbook.xml.rels", content: Data(workbookRelationships.utf8)),
            ZIPFixtureBuilder.Entry(name: "xl/worksheets/sheet1.xml", content: Data(sheet.utf8)),
        ])
    }

    /// Ein 1×1-Pixel-WebP als Bytes: ImageIO liest WebP seit macOS 11, kann es
    /// aber nicht auf jedem System schreiben.
    private static let minimalWebP = Data(
        base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"
    )!

    private func createImage(type: UTType, at url: URL) throws {
        if type == .webP {
            try Self.minimalWebP.write(to: url)
            return
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 32).fill()
        NSColor.black.setFill()
        NSRect(x: 8, y: 8, width: 20, height: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw XCTSkip("ImageIO cannot write \(type.identifier) on this system")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO could not finish \(type.identifier)")
        }
    }
}
