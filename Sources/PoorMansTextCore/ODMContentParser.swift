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
        /// Absätze können ineinander liegen: Eine ODF-Notiz mitten in einem
        /// Absatz enthält selbst wieder `text:p`. Mit nur einem Builder würde
        /// der innere Absatz den äußeren überschreiben und der Text davor und
        /// danach still verschwinden. Deshalb ein Stapel; oben liegt der
        /// gerade offene Absatz.
        private var texts = [TextBuilder]()

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
                texts.append(TextBuilder(headingLevel: headingLevel))
            } else if namespaceURI == Namespaces.text, elementName == "line-break",
                      !texts.isEmpty {
                // Markdown kennt den harten Umbruch als zwei Leerzeichen vor dem
                // Zeilenende; ein nacktes "\n" wäre nur ein weicher Umbruch und
                // ginge beim Rendern verloren.
                appendToOpenParagraph("  \n")
            } else if namespaceURI == Namespaces.text, elementName == "tab", !texts.isEmpty {
                appendToOpenParagraph(ODMText.literalTab)
            } else if namespaceURI == Namespaces.text, elementName == "s", !texts.isEmpty {
                let count = min(1_000, max(1, Int(odmAttribute("c", in: attributeDict) ?? "1") ?? 1))
                // Diese Leerzeichen stehen ausdrücklich im Dokument. Sie werden
                // als Platzhalter gesammelt, damit das Trimmen am Absatzende nur
                // den Leerraum der XML-Formatierung entfernt.
                appendToOpenParagraph(String(repeating: ODMText.literalSpace, count: count))
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            appendToOpenParagraph(string)
        }

        private func appendToOpenParagraph(_ string: String) {
            guard !texts.isEmpty else { return }
            let index = texts.count - 1
            if texts[index].needsSemanticBoundary {
                if !string.hasLeadingODMWhitespace,
                   !texts[index].value.hasTrailingODMWhitespace,
                   !texts[index].value.isEmpty,
                   !string.isEmpty {
                    texts[index].value.append(ODMText.literalSpace)
                }
                texts[index].needsSemanticBoundary = false
            }
            texts[index].value.append(string)
        }

        private func appendNestedParagraph(_ raw: String) {
            guard !texts.isEmpty else { return }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let index = texts.count - 1
            if !texts[index].value.isEmpty,
               !texts[index].value.hasTrailingODMWhitespace,
               !value.hasLeadingODMWhitespace {
                // Zwei semantische ODF-Absätze dürfen auch dann nicht zu einem
                // Wort verschmelzen, wenn die XML-Datei zwischen ihren Tags
                // keinerlei Formatierungsleerraum enthält.
                texts[index].value.append(ODMText.literalSpace)
            }
            texts[index].value.append(value)
            texts[index].needsSemanticBoundary = true
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if namespaceURI == Namespaces.text,
               (elementName == "h" || elementName == "p"),
               let text = texts.popLast() {
                if !texts.isEmpty {
                    // Ein Absatz in einer Notiz gehört an genau diese Stelle des
                    // noch offenen Elternabsatzes. Erst den äußeren Absatz als
                    // Ganzes zu maskieren verhindert außerdem doppelte Escapes.
                    appendNestedParagraph(text.value)
                    return
                }
                let value = ODMText.markdown(from: text.value)
                if !value.isEmpty {
                    let markdown = text.headingLevel.map {
                        String(repeating: "#", count: $0) + " " + value
                    } ?? value
                    append(.markdown(markdown))
                }
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
        var needsSemanticBoundary = false
    }

    private enum Namespaces {
        static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    }

    /// Macht aus dem gesammelten Absatztext gültiges Markdown.
    ///
    /// Drei Dinge müssen dabei zusammenpassen: Der Leerraum, den die XML-Datei
    /// nur zur eigenen Formatierung enthält, muss verschwinden; die
    /// ausdrücklichen Leerzeichen aus `text:s` müssen bleiben; und Zeichen, die
    /// Markdown als Auszeichnung liest, dürfen den Text nicht umdeuten. Ohne die
    /// Maskierung würde aus dem gewöhnlichen Absatz `# Text` eine Überschrift.
    enum ODMText {
        /// Platzhalter für ein Leerzeichen aus `text:s`. U+FFFF ist in
        /// XML-Inhalten nicht erlaubt und kann deshalb nie aus dem Dokument
        /// selbst stammen.
        static let literalSpace = "\u{FFFF}"
        static let literalTab = "\u{FFFE}"

        static func markdown(from raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let restored = trimmed
                .replacingOccurrences(of: literalSpace, with: " ")
                .replacingOccurrences(of: literalTab, with: "\t")
            guard !restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ""
            }
            return restored.split(separator: "\n", omittingEmptySubsequences: false)
                .map(escapedLine)
                .joined(separator: "\n")
        }

        /// Zeichen, die überall in der Zeile eine Auszeichnung beginnen können.
        private static let inlineSpecials: Set<Character> = [
            "\\", "`", "*", "_", "[", "]", "<", ">", "~", "&",
        ]

        private static func escapedLine(_ line: Substring) -> String {
            var escaped = ""
            for character in line {
                if inlineSpecials.contains(character) {
                    escaped.append("\\")
                }
                escaped.append(character)
            }
            return escapingLeadingBlockMarker(escaped)
        }

        /// Am Zeilenanfang entscheidet das erste sichtbare Zeichen über den
        /// Blocktyp: `# ` wäre eine Überschrift, `- ` oder `+ ` eine Liste,
        /// `1. ` eine nummerierte Liste und `=` eine Unterstreichungs-Überschrift.
        /// Genau dort kommt ein Backslash davor, im Rest der Zeile nicht — sonst
        /// stünde in jedem Bindestrich eines gewöhnlichen Wortes einer.
        private static func escapingLeadingBlockMarker(_ line: String) -> String {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line[indent.endIndex...]
            if indent.contains("\t") || indent.count >= 4 {
                // Vier Leerzeichen oder ein Tab eröffnen in GFM einen Codeblock.
                // Geschützte Leerzeichen bleiben sichtbar, ohne den Blocktyp des
                // ursprünglichen ODF-Absatzes zu verändern.
                let visibleIndent = indent.map { character in
                    character == "\t"
                        ? "&nbsp;&nbsp;&nbsp;&nbsp;"
                        : "&nbsp;"
                }.joined()
                return visibleIndent + rest
            }
            guard let first = rest.first else {
                return line
            }
            if "#-+=".contains(first) {
                return String(indent) + "\\" + rest
            }
            let digits = rest.prefix(while: \.isNumber)
            let afterDigits = rest[digits.endIndex...]
            if !digits.isEmpty, let marker = afterDigits.first, marker == "." || marker == ")" {
                return String(indent) + digits + "\\" + afterDigits
            }
            return line
        }
    }

    private struct ParserError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

private extension String {
    var hasLeadingODMWhitespace: Bool {
        guard let first else { return false }
        return first.isWhitespace
            || first == ODMContentParser.ODMText.literalSpace.first
            || first == ODMContentParser.ODMText.literalTab.first
    }

    var hasTrailingODMWhitespace: Bool {
        guard let last else { return false }
        return last.isWhitespace
            || last == ODMContentParser.ODMText.literalSpace.first
            || last == ODMContentParser.ODMText.literalTab.first
    }
}

private func odmAttribute(_ localName: String, in attributes: [String: String]) -> String? {
    attributes[localName] ?? attributes.first { $0.key.hasSuffix(":" + localName) }?.value
}
