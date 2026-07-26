import Foundation
import XCTest
@testable import PoorMansTextCore

/// Der Formatkatalog ist ein veröffentlichter Vertrag: Fastra und andere Hosts
/// entscheiden allein daraus, ob sie eine Datei zur Umwandlung anbieten. Diese
/// Tests sichern genau die Zusagen, auf die sich ein Host verlassen darf.
final class FormatCatalogTests: XCTestCase {

    func testEveryRegisteredFormatIsDescribedCompletely() {
        let descriptors = DocumentConverter().supportedFormatDescriptors

        // Die Deskriptoren sind die einzige Formatquelle — der alte
        // `supportedFormats`-Weg muss daraus exakt hervorgehen.
        XCTAssertEqual(
            Set(descriptors.map(\.format)),
            DocumentConverter().supportedFormats
        )

        for descriptor in descriptors {
            XCTAssertFalse(
                descriptor.fileExtensions.isEmpty,
                "\(descriptor.format.rawValue) has no file extension"
            )
            for fileExtension in descriptor.fileExtensions {
                XCTAssertFalse(fileExtension.hasPrefix("."), "extensions are stored without a dot")
                XCTAssertEqual(
                    fileExtension, fileExtension.lowercased(),
                    "extensions are stored lowercase"
                )
            }
            XCTAssertFalse(
                descriptor.requiredTools.isEmpty,
                "\(descriptor.format.rawValue) claims to need no external tool"
            )
        }

        // Eine Endung darf höchstens ein Format bezeichnen, sonst könnte ein Host
        // sie nicht eindeutig zuordnen.
        let allExtensions = descriptors.flatMap(\.fileExtensions)
        XCTAssertEqual(allExtensions.count, Set(allExtensions).count)
    }

    func testRTFDIsTheOnlyPackageFormat() {
        let packages = DocumentConverter().supportedFormatDescriptors
            .filter { $0.containerKind == .package }
            .map(\.format)
        // Ein Host, der Ordner sonst als Projekt öffnet, braucht diese
        // Unterscheidung; RTFD ist der Grund, dass es sie überhaupt gibt.
        XCTAssertEqual(packages, [.rtfd])
    }

    func testMissingToolMakesOnlyTheAffectedFormatsUnavailable() {
        let catalog = DocumentConverter(adapters: [
            StubAdapter(format: InputFormat(rawValue: "alpha"), tools: [.pandoc]),
            StubAdapter(format: InputFormat(rawValue: "beta"), tools: []),
        ]).formatCatalog(resolver: ExternalToolResolver(
            pandocExecutable: URL(fileURLWithPath: "/nonexistent/pandoc")
        ))

        let alpha = try? XCTUnwrap(catalog.first { $0.format.format.rawValue == "alpha" })
        XCTAssertEqual(alpha?.isAvailable, false)
        XCTAssertEqual(alpha?.missingTools, [.pandoc])
        XCTAssertNotNil(alpha?.unavailableReason)

        let beta = try? XCTUnwrap(catalog.first { $0.format.format.rawValue == "beta" })
        XCTAssertEqual(beta?.isAvailable, true)
        XCTAssertEqual(beta?.missingTools, [])
        XCTAssertNil(beta?.unavailableReason)
    }

    func testUnknownToolCountsAsUnavailable() {
        // Sichere Richtung: Ein Werkzeug ohne Prüfweg darf kein Format
        // fälschlich als benutzbar melden.
        let catalog = DocumentConverter(adapters: [
            StubAdapter(
                format: InputFormat(rawValue: "gamma"),
                tools: [ExternalTool(rawValue: "not-a-known-tool")]
            )
        ]).formatCatalog()

        XCTAssertEqual(catalog.first?.isAvailable, false)
        XCTAssertEqual(catalog.first?.missingTools.map(\.rawValue), ["not-a-known-tool"])
    }

    func testTextutilAvailabilityUsesTheSamePathTheAdapterRuns() {
        // Wenn Prüfpfad und Aufrufpfad auseinanderliefen, würde der Katalog
        // Verfügbarkeit für ein Format melden, das dann doch scheitert.
        XCTAssertEqual(LegacyWordAdapter.textutilPath, "/usr/bin/textutil")
        XCTAssertTrue(ExternalToolResolver().isAvailable(.textutil))
    }
}

/// Minimaladapter ohne echte Konvertierung — nur für die Katalogsicht.
private struct StubAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors: [SupportedFormat]

    init(format: InputFormat, tools: [ExternalTool]) {
        self.supportedFormatDescriptors = [
            SupportedFormat(
                format: format,
                fileExtensions: [format.rawValue],
                containerKind: .file,
                requiredTools: tools
            )
        ]
    }

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection { .noMatch }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        throw ConversionError.unsupportedInput(context.inputURL)
    }
}
