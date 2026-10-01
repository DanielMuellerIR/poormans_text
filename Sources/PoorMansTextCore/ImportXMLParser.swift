import Foundation

/// Ein `XMLParser`, wie ihn jeder Leser eines fremden Dokumentpakets braucht.
///
/// Die drei Einstellungen standen vorher an acht Stellen einzeln, siebenmal
/// wortgleich — und an der achten fehlte die wichtigste (Review-Fund
/// 2026-09-10). Hier stehen sie einmal:
///
/// - **Namensraumverarbeitung.** Ohne sie liefert `XMLParser` den Elementnamen
///   samt Präfix (`r:Relationship`), und ein Paket mit einem anderen — aber
///   völlig gültigen — Präfix rutscht an jeder Namensprüfung vorbei. Mit ihr ist
///   `elementName` der lokale Name.
/// - **Gemeldete Präfixdeklarationen.** Attributnamen behalten ihr Präfix auch
///   dann. Damit ein Delegate es auflösen kann, meldet
///   `shouldReportNamespacePrefixes` zusätzlich jede Präfix-Deklaration; ohne
///   dieses Flag ruft `XMLParser` die zugehörigen Delegate-Methoden gar nicht
///   erst auf. In die Attributliste geraten die `xmlns`-Deklarationen dadurch
///   nicht.
/// - **Keine externen Entitäten.** Ein fremdes Paket darf über eine
///   Entitätsdeklaration nichts nachladen. Foundation stellt das zwar auf
///   `false` vor; als Sicherheitseigenschaft gehört sie trotzdem in den Code
///   und nicht in eine Voreinstellung.
enum ImportXMLParser {
    static func make(_ xml: Data, delegate: any XMLParserDelegate) -> XMLParser {
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        return parser
    }
}
