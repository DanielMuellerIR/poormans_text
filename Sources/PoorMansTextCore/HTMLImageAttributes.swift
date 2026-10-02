import Foundation

/// Attribute immer als Ganzes lesen: `data-src` und ein `src=` innerhalb
/// eines Alt-Texts sind keine Bildquelle. Beide Bildstufen nutzen dieselben
/// Bereiche, damit Prüfung und Ersetzung auf dasselbe Attribut zeigen.
enum HTMLImageAttributes {
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
