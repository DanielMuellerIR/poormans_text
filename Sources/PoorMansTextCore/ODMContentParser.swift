import Foundation

enum ODMContentItem: Equatable {
    case markdown(String)
    case section(name: String?, reference: String)
}

enum ODMContentParser {
    static func parse(_ xml: Data) throws -> [ODMContentItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        guard !delegate.items.isEmpty else {
            throw ParserError("the ODM content contains no text or linked sections")
        }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items = [ODMContentItem]()
        private var sections = [SectionBuilder]()
        private var text: TextBuilder?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if namespaceURI == Namespaces.text, elementName == "section" {
                sections.append(
                    SectionBuilder(name: odmAttribute("name", in: attributeDict))
                )
            } else if namespaceURI == Namespaces.text, elementName == "section-source",
                      !sections.isEmpty,
                      let reference = odmAttribute("href", in: attributeDict) {
                sections[sections.count - 1].reference = reference
            } else if namespaceURI == Namespaces.text,
                      (elementName == "h" || elementName == "p") {
                let headingLevel = elementName == "h"
                    ? min(6, max(1, Int(odmAttribute("outline-level", in: attributeDict) ?? "1") ?? 1))
                    : nil
                text = TextBuilder(headingLevel: headingLevel)
            } else if namespaceURI == Namespaces.text, elementName == "line-break", text != nil {
                text?.value.append("\n")
            } else if namespaceURI == Namespaces.text, elementName == "tab", text != nil {
                text?.value.append("\t")
            } else if namespaceURI == Namespaces.text, elementName == "s", text != nil {
                let count = min(1_000, max(1, Int(odmAttribute("c", in: attributeDict) ?? "1") ?? 1))
                text?.value.append(String(repeating: " ", count: count))
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text?.value.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if namespaceURI == Namespaces.text,
               (elementName == "h" || elementName == "p"),
               let text {
                let value = text.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    let markdown = text.headingLevel.map {
                        String(repeating: "#", count: $0) + " " + value
                    } ?? value
                    append(.markdown(markdown))
                }
                self.text = nil
            } else if namespaceURI == Namespaces.text, elementName == "section",
                      let section = sections.popLast() {
                let sectionItems: [ODMContentItem]
                if let reference = section.reference {
                    sectionItems = [.section(name: section.name, reference: reference)]
                } else {
                    sectionItems = section.items
                }
                if sections.isEmpty {
                    items.append(contentsOf: sectionItems)
                } else {
                    sections[sections.count - 1].items.append(contentsOf: sectionItems)
                }
            }
        }

        private func append(_ item: ODMContentItem) {
            if sections.isEmpty {
                items.append(item)
            } else {
                sections[sections.count - 1].items.append(item)
            }
        }
    }

    private struct SectionBuilder {
        let name: String?
        var reference: String?
        var items = [ODMContentItem]()
    }

    private struct TextBuilder {
        let headingLevel: Int?
        var value = ""
    }

    private enum Namespaces {
        static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    }

    private struct ParserError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

private func odmAttribute(_ localName: String, in attributes: [String: String]) -> String? {
    attributes[localName] ?? attributes.first { $0.key.hasSuffix(":" + localName) }?.value
}
