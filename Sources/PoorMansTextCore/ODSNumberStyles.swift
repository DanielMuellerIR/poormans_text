import Foundation

/// ODF-Styles werden vor dem Tabellenkörper begrenzt gesammelt. Die gemeinsame
/// Formatierung erhält nur die belegbar entsprechende Excel-Teilmenge.
struct ODSNumberStyles {
    private var dataStyles: [String: ImportXML] = [:]
    private var cellStyles: [String: ImportXML] = [:]
    private var defaultCellStyle: ImportXML?
    private var compiled: [String: DataStyle] = [:]

    static func parse(content: Data, styles: Data?) throws -> Self {
        var result = Self()
        if let styles { try result.read(styles, root: "document-styles") }
        try result.read(content, root: "document-content")
        return result
    }

    private mutating func read(_ xml: Data, root: String) throws {
        let delegate = Collector(rootName: root)
        let parser = ImportXMLParser.make(xml, delegate: delegate)
        let success = parser.parse()
        try ConversionExecution.check()
        guard delegate.failure == nil, success || delegate.reachedBody else {
            throw delegate.failure ?? parser.parserError ?? ImportFailure("invalid ODS styles")
        }
        for node in delegate.styles {
            if node.namespace == NS.number, let name = node.attribute("name", namespace: NS.style) {
                dataStyles[name] = node
            } else if node.name == "default-style" {
                defaultCellStyle = node
            } else if let name = node.attribute("name", namespace: NS.style) {
                cellStyles[name] = node
            }
        }
        guard dataStyles.count + cellStyles.count <= 65_536 else { throw ImportFailure("ODS styles exceed their count limit") }
    }

    mutating func format(_ raw: String, type: String?, styleName: String?, nullDate: String) -> SpreadsheetFormattedNumber {
        func fallback(_ reason: String) -> SpreadsheetFormattedNumber { .init(text: raw, issue: reason) }
        do {
            guard let dataName = try dataStyleName(for: styleName) else { return .init(text: raw, issue: nil) }
            let style: DataStyle
            if let cached = compiled[dataName] { style = cached }
            else {
                guard let node = dataStyles[dataName] else { return fallback("the ODS data style is missing") }
                let precision = defaultCellStyle?.elements("table-cell-properties", namespace: NS.style).first?.attribute("decimal-places", namespace: NS.style)
                style = DataStyle(node: node, inheritedPrecision: precision)
                compiled[dataName] = style
            }
            if let issue = style.issue { return fallback(issue) }
            var value = raw
            if type == "date" {
                guard style.kind == "date-style", let date = Self.dateSerial(raw) else {
                    return fallback("the ODS date or its format is outside the supported ISO calendar subset")
                }
                value = date
            } else if type == "time" {
                guard style.kind == "time-style", let duration = Self.durationSerial(raw) else {
                    return fallback("the ODS duration or its format is unsupported")
                }
                value = duration
            } else if !["float", "currency", "percentage"].contains(type ?? "") {
                return .init(text: raw, issue: nil)
            } else if style.kind == "date-style" {
                guard let offset = Self.dateSerial(nullDate), let number = SpreadsheetNumberFormat.decimal(raw),
                      let base = SpreadsheetNumberFormat.decimal(offset) else { return fallback("the ODS null date or numeric date is unsupported") }
                value = NSDecimalNumber(decimal: number + base).stringValue
            }
            if style.kind == "percentage-style" {
                guard let number = SpreadsheetNumberFormat.decimal(value) else {
                    return fallback("the ODS percentage is outside the supported decimal range")
                }
                value = NSDecimalNumber(decimal: number * 100).stringValue
            }
            let rendered = style.format.format(value, dateSystem: .openDocument)
            return rendered.issue == nil ? rendered : fallback(rendered.issue!)
        } catch { return fallback(error.localizedDescription) }
    }

    private func dataStyleName(for name: String?) throws -> String? {
        var node: ImportXML?
        if let name {
            guard let found = cellStyles[name] else { throw ImportFailure("the ODS cell style is missing") }
            node = found
        } else { node = defaultCellStyle }
        var visited = Set<String>()
        while let style = node {
            if let data = style.attribute("data-style-name", namespace: NS.style) { return data }
            guard let parent = style.attribute("parent-style-name", namespace: NS.style) else {
                if style !== defaultCellStyle { node = defaultCellStyle; continue }
                return nil
            }
            guard visited.insert(parent).inserted, visited.count <= 128, let found = cellStyles[parent] else {
                throw ImportFailure("the ODS cell-style inheritance is cyclic, missing or too deep")
            }
            node = found
        }
        return nil
    }

    private static func dateSerial(_ raw: String) -> String? {
        guard raw.utf8.count <= 64,
              let expression = try? NSRegularExpression(pattern: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,6})?)?$"#),
              let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
        func part(_ index: Int) -> String? { Range(match.range(at: index), in: raw).map { String(raw[$0]) } }
        guard let yearText = part(1), let monthText = part(2), let dayText = part(3),
              let year = Int(yearText), let month = Int(monthText), let day = Int(dayText),
              let hour = Int(part(4) ?? "0"), let minute = Int(part(5) ?? "0"), let second = Int(part(6) ?? "0"),
              (1...9999).contains(year), hour < 24, minute < 60, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components,
              let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30)),
              let days = calendar.dateComponents([.day], from: base, to: date).day else { return nil }
        let seconds = Decimal(hour * 3600 + minute * 60 + second) + (Decimal(string: "0" + (part(7) ?? "")) ?? 0)
        return serialText(Decimal(days) + seconds / 86400)
    }

    private static func durationSerial(_ raw: String) -> String? {
        guard raw.utf8.count <= 128,
              let expression = try? NSRegularExpression(pattern: #"^(-)?P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d{1,6})?)S)?)?$"#),
              let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
        func part(_ index: Int) -> String? { Range(match.range(at: index), in: raw).map { String(raw[$0]) } }
        guard (2...5).contains(where: { part($0) != nil }), !raw.hasSuffix("T") else { return nil }
        let values = (2...5).map { Decimal(string: part($0) ?? "0") }
        guard values.allSatisfy({ $0 != nil && !$0!.isNaN }), values.allSatisfy({ $0! <= 1_000_000_000 }) else { return nil }
        let seconds = values[0]! * 86400 + values[1]! * 3600 + values[2]! * 60 + values[3]!
        return serialText((part(1) == nil ? seconds : -seconds) / 86400)
    }

    private static func serialText(_ value: Decimal) -> String {
        // Periodische Tagesbrüche brauchen keine 38 Nachkommastellen. 18 halten
        // die unterstützten Mikrosekunden, ohne Dezimal-Artefakte weiterzugeben.
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 18, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    private struct DataStyle {
        let kind: String
        let format: SpreadsheetNumberFormat
        let issue: String?

        init(node: ImportXML, inheritedPrecision: String?) {
            kind = node.name
            do {
                guard ["number-style", "percentage-style", "currency-style", "date-style", "time-style"].contains(kind) else {
                    throw ImportFailure("the ODS data-style kind is unsupported")
                }
                var code = try Self.localeCode(node)
                let elapsed = node.attribute("truncate-on-overflow", namespace: NS.number) == "false"
                let components = node.children.filter { $0.namespace == NS.number }.map(\.name)
                let largestTimeComponent = ["hours", "minutes", "seconds"].first(where: components.contains)
                for child in node.children {
                    if child.namespace == NS.style, child.name == "text-properties" { continue }
                    guard child.namespace == NS.number else { throw ImportFailure("conditional or extended ODS number styles are unsupported") }
                    if child.attribute("calendar", namespace: NS.number) != nil { throw ImportFailure("an alternate ODS calendar is unsupported") }
                    if child.attribute("possessive-form", namespace: NS.number) == "true" { throw ImportFailure("possessive ODS month names are unsupported") }
                    let long = child.attribute("style", namespace: NS.number) == "long"
                    switch child.name {
                    case "number", "scientific-number":
                        guard child.children.isEmpty, child.attribute("display-factor", namespace: NS.number).map({ $0 == "1" }) ?? true,
                              child.attribute("decimal-replacement", namespace: NS.number) == nil,
                              child.attribute("exponent-interval", namespace: NS.number).map({ $0 == "1" }) ?? true else {
                            throw ImportFailure("an extended ODS numeric pattern is unsupported")
                        }
                        let integers = try Self.count(child, "min-integer-digits", default: 1, maximum: 128)
                        let decimals: Int
                        let minimum: Int
                        if child.attribute("decimal-places", namespace: NS.number) == nil {
                            guard let raw = inheritedPrecision, let precision = Int(raw), (0...30).contains(precision) else {
                                throw ImportFailure("the ODS number style inherits an unspecified decimal precision")
                            }
                            decimals = precision
                            minimum = try Self.count(child, "min-decimal-places", default: 0, maximum: decimals)
                        } else {
                            decimals = try Self.count(child, "decimal-places", default: 0, maximum: 30)
                            minimum = try Self.count(child, "min-decimal-places", default: decimals, maximum: decimals)
                        }
                        code += child.attribute("grouping", namespace: NS.number) == "true" ? "#,##" : ""
                        code += integers == 0 ? "#" : String(repeating: "0", count: integers)
                        if decimals > 0 { code += "." + String(repeating: "0", count: minimum) + String(repeating: "#", count: decimals - minimum) }
                        if child.name == "scientific-number" {
                            let digits = try Self.count(child, "min-exponent-digits", default: 1, maximum: 12)
                            code += child.attribute("forced-exponent-sign", namespace: NS.number) == "true" ? "E+" : "E-"
                            code += String(repeating: "0", count: max(1, digits))
                        }
                    case "text", "currency-symbol":
                        guard child.children.isEmpty, child.name != "currency-symbol" || !child.text.isEmpty else {
                            throw ImportFailure("an implicit or structured ODS currency symbol is unsupported")
                        }
                        code += Self.literal(child.text)
                    case "year": code += long ? "yyyy" : "yy"
                    case "month":
                        let textual = child.attribute("textual", namespace: NS.number) == "true"
                        code += textual ? (long ? "mmmm" : "mmm") : (long ? "mm" : "m")
                    case "day": code += long ? "dd" : "d"
                    case "day-of-week": code += long ? "dddd" : "ddd"
                    case "hours", "minutes", "seconds":
                        let letter = child.name == "hours" ? "h" : child.name == "minutes" ? "m" : "s"
                        guard child.name != "minutes" || components.contains("hours") || components.contains("seconds") || elapsed else {
                            throw ImportFailure("an isolated ODS clock-minute pattern is unsupported")
                        }
                        let token = String(repeating: letter, count: long ? 2 : 1)
                        if elapsed && child.name == largestTimeComponent { code += "[" + token + "]" }
                        else { code += token }
                        if child.name == "seconds" {
                            let decimals = try Self.count(child, "decimal-places", default: 0, maximum: 6)
                            if decimals > 0 { code += "." + String(repeating: "0", count: decimals) }
                        }
                    case "am-pm": code += "AM/PM"
                    default: throw ImportFailure("the ODS number style contains an unsupported component")
                    }
                }
                guard node.attribute("automatic-order", namespace: NS.number) != "true",
                      node.attribute("format-source", namespace: NS.number) != "language" else {
                    throw ImportFailure("automatic ODS date ordering is unsupported")
                }
                format = SpreadsheetNumberFormat(code: code)
                issue = nil
            } catch {
                issue = error.localizedDescription
                format = SpreadsheetNumberFormat(unsupported: error.localizedDescription)
            }
        }

        private static func literal(_ text: String) -> String {
            text.map { "\\" + String($0) }.joined()
        }

        private static func count(_ node: ImportXML, _ name: String, default fallback: Int, maximum: Int) throws -> Int {
            guard let raw = node.attribute(name, namespace: NS.number) else { return fallback }
            guard let value = Int(raw), value >= 0, value <= maximum else { throw ImportFailure("an ODS numeric-pattern width is invalid or too large") }
            return value
        }

        private static func localeCode(_ node: ImportXML) throws -> String {
            guard node.attribute("transliteration-format", namespace: NS.number) == nil,
                  node.attribute("transliteration-style", namespace: NS.number) == nil,
                  node.attribute("script", namespace: NS.number) == nil else { throw ImportFailure("ODS transliteration is unsupported") }
            let language = node.attribute("language", namespace: NS.number)
            let country = node.attribute("country", namespace: NS.number)
            let tag = node.attribute("rfc-language-tag", namespace: NS.number) ?? language.map { $0 + (country.map { "-" + $0 } ?? "") }
            guard let tag else { return "" }
            let locales = ["en": "409", "en-US": "409", "en-GB": "809", "de": "407", "de-DE": "407", "fr": "40c", "fr-FR": "40c",
                           "it-IT": "410", "es-ES": "40a", "ja-JP": "411", "nl-NL": "413", "pt-BR": "416"]
            guard let id = locales[tag] else { throw ImportFailure("the ODS number-style locale is unsupported") }
            return "[$-" + id + "]"
        }
    }

    private final class Collector: NSObject, XMLParserDelegate {
        let rootName: String
        var styles: [ImportXML] = []
        var failure: Error?
        var reachedBody = false
        private var stack: [ImportXML] = []
        private var depth = 0
        private var inStyles = false
        private var nodes = 0
        private var attributes = 0
        private var bytes = 0
        private var names = Set<String>()
        private let prefixes = NamespacePrefixTracker()
        init(rootName: String) { self.rootName = rootName }
        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { prefixes.startMapping(prefix: prefix, uri: namespaceURI) }
        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { prefixes.endMapping(prefix: prefix) }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes values: [String: String]) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            depth += 1
            guard depth <= 128 else { return fail("ODS style XML exceeds its depth limit", parser) }
            if depth == 1 {
                guard name == rootName, namespaceURI == NS.office else { return fail("invalid ODS styles root", parser) }
            }
            if depth == 2, namespaceURI == NS.office, name == "body", rootName == "document-content" {
                reachedBody = true; parser.abortParsing(); return
            }
            if depth == 2, namespaceURI == NS.office, ["styles", "automatic-styles"].contains(name) { inStyles = true; return }
            guard inStyles else { return }
            nodes += 1; attributes += values.count
            bytes += values.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            guard nodes <= 200_000, attributes <= 200_000, bytes <= 1_048_576 else { return fail("ODS styles exceed their node/attribute/byte limit", parser) }
            if depth == 3 {
                let isCell = namespaceURI == NS.style && ["style", "default-style"].contains(name)
                    && prefixes.attributeValue(localName: "family", namespaceURI: NS.style, in: values) == "table-cell"
                guard namespaceURI == NS.number || isCell else { return }
            } else if stack.isEmpty { return }
            var expanded: [String: String] = [:]
            for (key, value) in values {
                let parts = key.split(separator: ":", maxSplits: 1)
                let ns = parts.count == 2 ? prefixes.namespaceURI(for: String(parts[0])) ?? "?" : ""
                let expandedName = ns + "|" + String(parts.last!)
                guard expanded[expandedName] == nil else { return fail("duplicate expanded ODS style attributes", parser) }
                expanded[expandedName] = value
            }
            let node = ImportXML(name: name, namespace: namespaceURI ?? "", attributes: expanded)
            if let parent = stack.last { parent.children.append(node); parent.content.append(.element(node)) }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { depth -= 1 }
            if depth == 2 { inStyles = false }
            guard !stack.isEmpty else { return }
            let node = stack.removeLast()
            if stack.isEmpty {
                let key = node.namespace + "|" + (node.attribute("name", namespace: NS.style) ?? node.name)
                guard names.insert(key).inserted else { return fail("duplicate ODS style names", parser) }
                styles.append(node)
            }
        }
        func parser(_ parser: XMLParser, foundCharacters text: String) {
            guard let node = stack.last else { return }
            bytes += text.utf8.count
            guard bytes <= 1_048_576 else { return fail("ODS styles exceed their text limit", parser) }
            node.content.append(.text(text))
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self)) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { fail("ODS entity declarations are unsupported", parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { fail("ODS external entities are unsupported", parser) }
        private func fail(_ reason: String, _ parser: XMLParser) { failure = ImportFailure(reason); parser.abortParsing() }
    }

    private enum NS {
        static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
        static let style = "urn:oasis:names:tc:opendocument:xmlns:style:1.0"
        static let number = "urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0"
    }
}
