import Foundation

/// Kleiner begrenzter XML-Baum für einzelne Folien/Metadaten. Externe Entitäten
/// werden nie aufgelöst; der Parser prüft Abbruch auch während langer Textläufe.
final class ImportXML {
    let name: String
    let namespace: String
    let attributes: [String: String]
    var children: [ImportXML] = []
    var content: [Content] = []
    enum Content { case text(String), element(ImportXML) }
    init(name: String, namespace: String, attributes: [String: String]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes
    }
    func attribute(_ name: String, namespace: String = "") -> String? { attributes[namespace + "|" + name] }
    func elements(_ name: String, namespace: String) -> [ImportXML] { children.filter { $0.name == name && $0.namespace == namespace } }
    func descendants(_ name: String, namespace: String) -> [ImportXML] {
        children.flatMap { ($0.name == name && $0.namespace == namespace ? [$0] : []) + $0.descendants(name, namespace: namespace) }
    }
    var text: String { content.map { switch $0 { case .text(let text): text; case .element(let node): node.text } }.joined() }
    static func parse(_ data: Data) throws -> ImportXML {
        guard data.count <= 16 * 1_024 * 1_024 else { throw ImportFailure("XML exceeds the 16 MiB entry limit") }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let success = parser.parse()
        try ConversionExecution.check()
        guard success, delegate.failure == nil, let root = delegate.root else {
            throw delegate.failure ?? parser.parserError ?? ImportFailure("invalid XML")
        }
        return root
    }
    private final class Delegate: NSObject, XMLParserDelegate {
        var root: ImportXML?
        var stack: [ImportXML] = []
        var namespaces: [String: [String]] = [:]
        var nodes = 0
        var textBytes = 0
        var failure: Error?
        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { namespaces[prefix, default: []].append(namespaceURI) }
        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = namespaces[prefix]?.popLast() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            nodes += 1
            guard nodes <= 200_000, stack.count < 128 else { failure = ImportFailure("XML exceeds node/depth limits"); parser.abortParsing(); return }
            var expanded: [String: String] = [:]
            for (key, value) in attributes {
                let parts = key.split(separator: ":", maxSplits: 1)
                let namespace = parts.count == 2 ? namespaces[String(parts[0])]?.last ?? "?" : ""
                expanded[namespace + "|" + String(parts.last!)] = value
            }
            let node = ImportXML(name: name, namespace: namespaceURI ?? "", attributes: expanded)
            if let parent = stack.last { parent.children.append(node); parent.content.append(.element(node)) }
            else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            textBytes += string.utf8.count
            guard textBytes <= 16 * 1_024 * 1_024 else { failure = ImportFailure("XML text exceeds its limit"); parser.abortParsing(); return }
            stack.last?.content.append(.text(string))
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self)) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            failure = ImportFailure("XML entity declarations are not supported"); parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            failure = ImportFailure("external XML entities are not supported"); parser.abortParsing()
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            failure = ImportFailure("external XML entities are not supported"); parser.abortParsing(); return nil
        }
    }
}

struct ImportFailure: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
