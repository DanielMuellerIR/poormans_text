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
    func attributeValue(
        localName: String,
        namespaceURI: String,
        in attributes: [String: String]
    ) -> String? {
        for (name, value) in attributes {
            guard let separator = name.firstIndex(of: ":"),
                  name[name.index(after: separator)...] == localName,
                  uris[String(name[..<separator])]?.last == namespaceURI else {
                continue
            }
            return value
        }
        return nil
    }
}
