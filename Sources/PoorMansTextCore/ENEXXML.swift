import Foundation

enum ENEXXML {
    static func prepared(_ source: String, root: String) throws -> String {
        var cursor = source.startIndex
        var declaration = false
        var doctype = false
        while cursor < source.endIndex {
            while cursor < source.endIndex, source[cursor].isWhitespace || source[cursor] == "\u{FEFF}" { cursor = source.index(after: cursor) }
            guard source[..<cursor].utf8.count <= 16_384 else { throw ImportFailure("the ENEX XML prolog exceeds its limit") }
            let tail = source[cursor...]
            if tail.hasPrefix("<?xml"), tail.dropFirst(5).first?.isWhitespace == true {
                guard !declaration, !doctype, let end = tail.range(of: "?>") else { throw ImportFailure("invalid ENEX XML declaration") }
                let value = String(source[cursor..<end.upperBound])
                let pattern = #"^<\?xml\s+version=(?:"1\.0"|'1\.0')(?:\s+encoding=(?:"(?i:UTF-8)"|'(?i:UTF-8)'))?(?:\s+standalone=(?:"(?:yes|no)"|'(?:yes|no)'))?\s*\?>$"#
                guard value.range(of: pattern, options: .regularExpression) != nil else { throw ImportFailure("ENEX requires XML 1.0 and UTF-8") }
                declaration = true
                cursor = end.upperBound
            } else if tail.hasPrefix("<!--") {
                guard let end = tail.range(of: "-->") else { throw ImportFailure("an ENEX XML comment is incomplete") }
                cursor = end.upperBound
            } else if tail.hasPrefix("<!DOCTYPE") {
                guard !doctype, let end = tail.firstIndex(of: ">") else { throw ImportFailure("invalid ENEX DOCTYPE") }
                let value = String(source[cursor...end])
                let file = root == "en-export" ? "evernote-export[234]" : "enml2"
                let uri = #"https?://xml\.evernote\.com/pub/"# + file + #"\.dtd"#
                let identifier = "(?:\"" + uri + "\"|'" + uri + "')"
                let publicID = #"(?:"[^"<>\[\]]*"|'[^'<>\[\]]*')"#
                let pattern = "^<!DOCTYPE\\s+" + root + #"\s+(?:SYSTEM\s+"# + identifier + #"|PUBLIC\s+"# + publicID + #"\s+"# + identifier + #")\s*>$"#
                guard value.utf8.count <= 4096, value.range(of: pattern, options: .regularExpression) != nil else {
                    throw ImportFailure("the XML DOCTYPE is not a supported declarative Evernote reference")
                }
                // Auch bekannte DTDs werden vor dem Parser entfernt. So gibt es
                // keinen Auflösungsversuch und keinen internen Entitätssubset.
                doctype = true
                cursor = source.index(after: end)
            } else {
                guard tail.range(of: "^<" + root + #"(?:\s|/|>)"#, options: .regularExpression) != nil else {
                    throw ImportFailure("the XML root is not " + root)
                }
                return String(tail)
            }
        }
        throw ImportFailure("the ENEX XML document is empty")
    }

    static func parse(_ source: String, root: String) throws -> ImportXML {
        var xml = try prepared(source, root: root)
        if root == "en-note" { xml = try normalizedEntities(xml) }
        let bytes = Data(xml.utf8)
        guard bytes.count <= ENEXReader.maximumSourceBytes else { throw ImportFailure("the normalized XML exceeds its 16 MiB limit") }
        let gate = Gate(normalization: root == "en-note")
        let parser = ImportXMLParser.make(bytes, delegate: gate)
        let valid = parser.parse()
        try ConversionExecution.check()
        guard valid, gate.failure == nil else { throw gate.failure ?? parser.parserError ?? ImportFailure("invalid ENEX XML") }
        let node = try ImportXML.parse(bytes)
        guard node.name == root, node.namespace.isEmpty else { throw ImportFailure("an unexpected XML namespace was found in " + root) }
        return node
    }

    // Die Baumstruktur erweitert Attributnamen um ihre Namensräume. Fremde
    // Namensraumdeklarationen werden deshalb vor dieser Expansion abgewiesen.
    private final class Gate: NSObject, XMLParserDelegate {
        let normalization: Bool
        var failure: Error?
        var expandedBytes = 0
        var depth = 0
        var nodes = 0
        var attributeCount = 0
        init(normalization: Bool) { self.normalization = normalization }
        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
            if !uri.isEmpty { stop(parser, "XML namespaces are not supported in this ENEX reader") }
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            depth += 1
            nodes += 1
            attributeCount += attributes.count
            guard name.utf8.count <= 1024, attributes.count <= 128, depth <= 128, nodes <= 200_000, attributeCount <= 200_000 else {
                stop(parser, "ENEX XML exceeds its name, attribute, depth or node limit"); return
            }
            if normalization {
                expandedBytes += 64 + name.utf8.count * 2
                for (key, value) in attributes { expandedBytes += key.utf8.count + value.utf8.count * 10 + 8 }
                check(parser)
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
        func parser(_ parser: XMLParser, foundCharacters text: String) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            guard normalization else { return }
            expandedBytes += text.utf8.count
            for (index, scalar) in text.unicodeScalars.enumerated() {
                if index % 4096 == 0 {
                    if ConversionExecution.isCancelled { parser.abortParsing(); return }
                    if expandedBytes > CollectionLimits.maximumDocumentBytes { check(parser); return }
                }
                switch scalar.value { case 38: expandedBytes += 8; case 60, 62: expandedBytes += 7; case 34: expandedBytes += 9; default: break }
            }
            check(parser)
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self)) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { stop(parser, "XML entity declarations are not supported") }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { stop(parser, "external XML entities are not supported") }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { stop(parser, "external XML entities are not supported"); return nil }
        private func check(_ parser: XMLParser) {
            if expandedBytes > CollectionLimits.maximumDocumentBytes { stop(parser, "ENML normalization exceeds its expansion budget") }
        }
        private func stop(_ parser: XMLParser, _ reason: String) { failure = ImportFailure(reason); parser.abortParsing() }
    }

    private static func normalizedEntities(_ xml: String) throws -> String {
        let expression = try NSRegularExpression(pattern: #"<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|&([A-Za-z][A-Za-z0-9]{0,31});"#)
        let text = xml as NSString
        var result = ""
        var cursor = 0
        for match in expression.matches(in: xml, range: NSRange(location: 0, length: text.length)) {
            try ConversionExecution.check()
            result += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if match.range(at: 1).location == NSNotFound { result += text.substring(with: match.range) }
            else {
                let name = text.substring(with: match.range(at: 1))
                if ["amp", "lt", "gt", "quot", "apos"].contains(name) { result += text.substring(with: match.range) }
                else if let value = MarkdownCharacterReferences.named[name] {
                    result += value.unicodeScalars.map { "&#\($0.value);" }.joined()
                } else { throw ImportFailure("an unknown ENML character entity was found: " + name) }
            }
            cursor = NSMaxRange(match.range)
        }
        result += text.substring(from: cursor)
        return result
    }
}
