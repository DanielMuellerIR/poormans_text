import Foundation
import XCTest
@testable import PoorMansTextCore

/// Die drei Einstellungen jedes Paketleser-Parsers standen vorher an acht
/// Stellen einzeln; an einer fehlte die wichtigste. Diese Tests halten fest,
/// was die gemeinsame Fabrik zusichert (Review-Fund 2026-09-10).
final class ImportXMLParserTests: XCTestCase {
    private final class Collector: NSObject, XMLParserDelegate {
        var elements: [String] = []
        var namespaces: [String] = []
        var attributes: [[String: String]] = []
        var prefixes: [String: String] = [:]
        var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            elements.append(elementName)
            namespaces.append(namespaceURI ?? "")
            attributes.append(attributeDict)
        }

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixes[prefix] = namespaceURI
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }
    }

    /// Der Elementname ist der LOKALE Name, nicht der mit Präfix — sonst rutscht
    /// ein Paket mit einem anderen, völlig gültigen Präfix an jeder
    /// Namensprüfung vorbei.
    func testTheParserReportsLocalNamesAndPrefixDeclarations() {
        let collector = Collector()
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <fremd:Relationships xmlns:fremd="http://beispiel.test/rel">
        <fremd:Relationship fremd:Id="rId1" Target="bild.png"/>
        </fremd:Relationships>
        """.utf8)

        XCTAssertTrue(ImportXMLParser.make(xml, delegate: collector).parse())

        XCTAssertEqual(collector.elements, ["Relationships", "Relationship"])
        XCTAssertEqual(collector.namespaces, ["http://beispiel.test/rel", "http://beispiel.test/rel"])
        XCTAssertEqual(collector.prefixes, ["fremd": "http://beispiel.test/rel"])
        // Die `xmlns`-Deklaration steht nicht in der Attributliste, das
        // präfigierte Attribut behält dagegen sein Präfix.
        XCTAssertEqual(collector.attributes.first, [:])
        XCTAssertEqual(collector.attributes.last, ["fremd:Id": "rId1", "Target": "bild.png"])
    }

    /// Ein fremdes Paket darf über eine Entitätsdeklaration nichts nachladen.
    ///
    /// Ehrlich vermerkt: Dieser Test hält das VERHALTEN fest, nicht die
    /// Einstellung. Gemessen am 2026-09-10 löst Foundations `XMLParser` eine
    /// SYSTEM-Entität aus einem `Data`-Dokument auch dann nicht auf, wenn
    /// `shouldResolveExternalEntities` auf `true` steht — die Rückmutation der
    /// Zeile lässt diesen Test also nicht fehlschlagen. Er greift erst, wenn
    /// sich das Verhalten von Foundation je ändert.
    func testTheParserNeverResolvesAnExternalEntity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoorMansTextImportXMLParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = directory.appendingPathComponent("geheim.txt")
        try Data("STRENG-GEHEIM".utf8).write(to: secret)

        let collector = Collector()
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE wurzel [<!ENTITY fremd SYSTEM "\(secret.path)">]>
        <wurzel>&fremd;</wurzel>
        """.utf8)

        _ = ImportXMLParser.make(xml, delegate: collector).parse()

        XCTAssertFalse(collector.text.contains("STRENG-GEHEIM"), collector.text)
    }
}
