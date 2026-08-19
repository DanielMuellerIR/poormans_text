import Foundation
import XCTest
@testable import PoorMansTextCore

/// Direkte Prüfung der Präfix-Zuordnung, die alle drei XML-Parser des Kerns
/// benutzen. Bisher war sie nur mittelbar über die Adapter-Tests abgedeckt.
final class NamespacePrefixTrackerTests: XCTestCase {
    private let xlink = "http://www.w3.org/1999/xlink"
    private let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"

    func testReadsAnAttributeOnlyThroughAPrefixBoundToTheExpectedNamespace() throws {
        let tracker = NamespacePrefixTracker()
        tracker.startMapping(prefix: "xlink", uri: xlink)

        XCTAssertEqual(
            tracker.attributeValue(
                localName: "href",
                namespaceURI: xlink,
                in: ["xlink:href": "chapter.odt"]
            ),
            "chapter.odt"
        )
        // Gleicher lokaler Name, aber das Präfix zeigt woanders hin.
        XCTAssertNil(
            tracker.attributeValue(
                localName: "href",
                namespaceURI: xlink,
                in: ["text:href": "chapter.odt"]
            )
        )
    }

    func testAnUnprefixedAttributeNeverCounts() throws {
        // Ein Attribut ohne Präfix hat in XML keinen Namensraum. Die frühere
        // Suffix-Suche akzeptierte es dennoch.
        let tracker = NamespacePrefixTracker()
        tracker.startMapping(prefix: "xlink", uri: xlink)

        XCTAssertNil(
            tracker.attributeValue(
                localName: "href",
                namespaceURI: xlink,
                in: ["href": "chapter.odt"]
            )
        )
    }

    func testAnInnerRebindingWinsUntilItEnds() throws {
        let tracker = NamespacePrefixTracker()
        tracker.startMapping(prefix: "x", uri: xlink)
        XCTAssertEqual(
            tracker.attributeValue(localName: "href", namespaceURI: xlink, in: ["x:href": "aussen"]),
            "aussen"
        )

        // Dasselbe Präfix wird in einem inneren Element neu belegt.
        tracker.startMapping(prefix: "x", uri: text)
        XCTAssertNil(
            tracker.attributeValue(localName: "href", namespaceURI: xlink, in: ["x:href": "innen"])
        )
        XCTAssertEqual(
            tracker.attributeValue(localName: "href", namespaceURI: text, in: ["x:href": "innen"]),
            "innen"
        )

        tracker.endMapping(prefix: "x")
        XCTAssertEqual(
            tracker.attributeValue(localName: "href", namespaceURI: xlink, in: ["x:href": "aussen"]),
            "aussen"
        )

        // Nach dem letzten endMapping gilt das Präfix nicht mehr. Ein weiteres
        // endMapping darf nicht abstürzen.
        tracker.endMapping(prefix: "x")
        tracker.endMapping(prefix: "x")
        XCTAssertNil(
            tracker.attributeValue(localName: "href", namespaceURI: xlink, in: ["x:href": "aussen"])
        )
    }

    func testTwoPrefixesOnTheSameNamespaceResolveToTheSameAttributeEveryTime() throws {
        // `XMLParser` lehnt zwei Attribute mit demselben erweiterten Namen nicht
        // ab, obwohl XML sie verbietet. Welches im Dictionary zuerst kommt, hängt
        // am Hash-Seed des Prozesses: Dasselbe ODM lieferte über 20 Läufe
        // viermal das eine und sechzehnmal das andere Teildokument. Die Auswahl
        // muss deshalb allein am Attributnamen hängen.
        let tracker = NamespacePrefixTracker()
        tracker.startMapping(prefix: "xlink", uri: xlink)
        tracker.startMapping(prefix: "xl2", uri: xlink)

        for _ in 0..<200 {
            let attributes = ["xlink:href": "zweiter", "xl2:href": "erster"]
            XCTAssertEqual(
                tracker.attributeValue(
                    localName: "href",
                    namespaceURI: xlink,
                    in: attributes
                ),
                "erster",
                "Bei mehrdeutiger Eingabe muss stets der kleinste Attributname gewinnen."
            )
        }
    }

    func testALocalNameIsMatchedInFullAndNotAsASuffix() throws {
        // `xlink:xhref` endet auf „href", ist aber ein anderes Attribut.
        let tracker = NamespacePrefixTracker()
        tracker.startMapping(prefix: "xlink", uri: xlink)

        XCTAssertNil(
            tracker.attributeValue(
                localName: "href",
                namespaceURI: xlink,
                in: ["xlink:xhref": "falsch"]
            )
        )
    }
}
