import Foundation

/// Attribute immer als Ganzes lesen: `data-src` und ein `src=` innerhalb
/// eines Alt-Texts sind keine Bildquelle. Beide Bildstufen nutzen dieselben
/// Bereiche, damit Prüfung und Ersetzung auf dasselbe Attribut zeigen.
enum HTMLImageAttributes {
    static func decodedValue(_ value: String) throws -> String {
        let expression = try NSRegularExpression(pattern: #"&(?:#([0-9]+);?|#[xX]([0-9a-fA-F]+);?|([a-zA-Z][a-zA-Z0-9]{0,31})(;|(?![a-zA-Z0-9=])))"#)
        let source = value as NSString
        var pieces = [String]()
        var cursor = 0
        for match in expression.matches(in: value, range: NSRange(location: 0, length: source.length)) {
            try ConversionExecution.check()
            pieces.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let replacement: String?
            if match.range(at: 3).location != NSNotFound {
                let name = source.substring(with: match.range(at: 3))
                let hasSemicolon = match.range(at: 4).length == 1
                replacement = hasSemicolon || legacyNames.contains(name) ? MarkdownCharacterReferences.named[name] : nil
            } else {
                let hex = match.range(at: 2).location != NSNotFound
                let digits = source.substring(with: match.range(at: hex ? 2 : 1))
                let scalar = UInt32(digits, radix: hex ? 16 : 10)
                    .flatMap { UnicodeScalar(numericReplacements[$0] ?? $0) }
                replacement = scalar.flatMap { $0.value == 0 ? nil : String($0) } ?? "\u{FFFD}"
            }
            pieces.append(replacement ?? source.substring(with: match.range))
            cursor = NSMaxRange(match.range)
        }
        pieces.append(source.substring(from: cursor))
        return pieces.joined()
    }

    // HTML dekodiert diese historischen C1-Referenzen wie Windows-1252.
    // Nicht aufgeführte Steuerzeichen behalten ihren Unicode-Wert.
    // Quelle: https://html.spec.whatwg.org/multipage/parsing.html#numeric-character-reference-end-state
    private static let numericReplacements: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E,
        0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6,
        0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152,
        0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C,
        0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
        0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A,
        0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]

    // Quelle: https://html.spec.whatwg.org/entities.json
    // Nur diese historischen Namen dürfen im Attribut
    // ohne Semikolon stehen; vor ASCII-Buchstaben, Ziffern oder `=` bleiben sie literal.
    private static let legacyNames: Set<String> = [
        "AElig", "AMP", "Aacute", "Acirc", "Agrave", "Aring", "Atilde", "Auml", "COPY",
        "Ccedil", "ETH", "Eacute", "Ecirc", "Egrave", "Euml", "GT", "Iacute", "Icirc",
        "Igrave", "Iuml", "LT", "Ntilde", "Oacute", "Ocirc", "Ograve", "Oslash", "Otilde",
        "Ouml", "QUOT", "REG", "THORN", "Uacute", "Ucirc", "Ugrave", "Uuml", "Yacute",
        "aacute", "acirc", "acute", "aelig", "agrave", "amp", "aring", "atilde", "auml",
        "brvbar", "ccedil", "cedil", "cent", "copy", "curren", "deg", "divide", "eacute",
        "ecirc", "egrave", "eth", "euml", "frac12", "frac14", "frac34", "gt", "iacute",
        "icirc", "iexcl", "igrave", "iquest", "iuml", "laquo", "lt", "macr", "micro",
        "middot", "nbsp", "not", "ntilde", "oacute", "ocirc", "ograve", "ordf", "ordm",
        "oslash", "otilde", "ouml", "para", "plusmn", "pound", "quot", "raquo", "reg",
        "sect", "shy", "sup1", "sup2", "sup3", "szlig", "thorn", "times", "uacute",
        "ucirc", "ugrave", "uml", "uuml", "yacute", "yen", "yuml",
    ]

    struct Attribute {
        let value: String
        let range: NSRange
        let valueRange: NSRange
    }

    static func imageTags(in html: String) throws -> [NSTextCheckingResult] {
        try NSRegularExpression(pattern: #"<img\b(?:[^>"']|"[^"]*"|'[^']*')*>"#,
            options: [.caseInsensitive]).matches(in: html, range: NSRange(location: 0, length: (html as NSString).length))
    }

    static func read(in tag: String) throws -> [String: Attribute] {
        let expression = try NSRegularExpression(
            pattern: #"\s+([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)
        let source = tag as NSString
        var attributes = [String: Attribute]()
        for match in expression.matches(in: tag, range: NSRange(location: 0, length: source.length)) {
            let nameRange = match.range(at: 1)
            let name = source.substring(with: nameRange).lowercased()
            let valueRange = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            if attributes[name] == nil {
                attributes[name] = Attribute(value: source.substring(with: valueRange),
                    range: NSRange(location: nameRange.location, length: NSMaxRange(match.range) - nameRange.location),
                    valueRange: valueRange)
            }
        }
        return attributes
    }
}
