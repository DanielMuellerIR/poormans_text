import Foundation

/// Die im Dokument deklarierten Namensraum-Präfixe, solange sie gelten.
///
/// `XMLParser` löst mit `shouldProcessNamespaces` zwar Elementnamen auf, liefert
/// Attributnamen aber weiterhin mit ihrem Präfix. Ohne diese Zuordnung müsste
/// man das Präfix raten — und ein beliebiges fremdes `foo:href` würde den
/// echten `xlink:href` verdecken. Weil dasselbe Präfix in einem inneren Element
/// neu belegt werden darf, steht je Präfix ein Stapel.
final class NamespacePrefixTracker {
    private var uris = [String: [String]]()

    func startMapping(prefix: String, uri: String) {
        uris[prefix, default: []].append(uri)
    }

    func endMapping(prefix: String) {
        guard var stack = uris[prefix], !stack.isEmpty else { return }
        stack.removeLast()
        uris[prefix] = stack.isEmpty ? nil : stack
    }

    /// Der Wert des Attributs, dessen Präfix wirklich auf den erwarteten
    /// Namensraum zeigt. Ein unpräfigiertes Attribut hat in XML keinen
    /// Namensraum und zählt deshalb nie.
    ///
    /// Zwei Attribute mit demselben Namensraum und Namen sind laut „Namespaces
    /// in XML" verboten, aber `XMLParser` lehnt sie nicht ab: `xlink:href` und
    /// ein zweites Präfix auf denselben Namensraum kommen beide im Dictionary
    /// an. Dessen Reihenfolge hängt am Hash-Seed des Prozesses, weshalb sich
    /// dasselbe Dokument von Lauf zu Lauf anders verhielt — gemessen an einem
    /// ODM mit zwei `href`-Attributen: 20 Läufe, 4-mal das eine und 16-mal das
    /// andere Teildokument. Deshalb hier der kleinste passende Attributname:
    /// welcher gewinnt, ist bei ungültiger Eingabe willkürlich, aber es ist in
    /// jedem Lauf derselbe.
    func attributeValue(
        localName: String,
        namespaceURI: String,
        in attributes: [String: String]
    ) -> String? {
        var chosen: (name: String, value: String)?
        for (name, value) in attributes {
            guard let separator = name.firstIndex(of: ":"),
                  name[name.index(after: separator)...] == localName,
                  uris[String(name[..<separator])]?.last == namespaceURI else {
                continue
            }
            if chosen == nil || name < chosen!.name {
                chosen = (name, value)
            }
        }
        return chosen?.value
    }
}
