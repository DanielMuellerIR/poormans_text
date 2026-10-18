import Foundation

struct ENMLConverter {
    private(set) var warnings: [ConversionWarning] = []
    private let resources: ENEXResources?
    private let noteLinks: ENEXNoteLinks?
    private let markdownName: String
    init(resources: ENEXResources? = nil, noteLinks: ENEXNoteLinks? = nil, markdownName: String = "") {
        self.resources = resources
        self.noteLinks = noteLinks
        self.markdownName = markdownName
    }
    private static let elements: Set<String> = ["a", "abbr", "acronym", "address", "b", "bdo", "big", "blockquote", "br", "caption", "center", "cite", "code", "col", "colgroup", "dd", "del", "dfn", "div", "dl", "dt", "em", "font", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "map", "ol", "p", "pre", "q", "s", "samp", "small", "span", "strike", "strong", "sub", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "tt", "u", "ul", "var"]

    mutating func convert(_ content: String) throws -> String {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let root = try ENEXXML.parse(content, root: "en-note")
        return try children(root)
    }

    private mutating func children(_ node: ImportXML) throws -> String {
        var html = ""
        for part in node.content {
            try ConversionExecution.check()
            switch part {
            case .text(let text): html += Self.escaped(text)
            case .element(let child): html += try render(child)
            }
            guard html.utf8.count <= CollectionLimits.maximumDocumentBytes else { throw ImportFailure("normalized ENML exceeds its size limit") }
        }
        return html
    }

    private mutating func render(_ node: ImportXML) throws -> String {
        guard node.namespace.isEmpty else { return unsupported(node) }
        switch node.name {
        case "en-todo":
            let state = node.attribute("checked") ?? "false"
            guard ["true", "false"].contains(state), node.children.isEmpty, node.text.isEmpty else { return unsupported(node) }
            return "<span>" + (state == "true" ? "☑" : "☐") + "</span>"
        case "en-media":
            guard node.children.isEmpty, node.text.isEmpty else { return unsupported(node) }
            if let resources {
                let resolved = resources.media(node)
                if let warning = resolved.warning { warnings.append(warning) }
                return resolved.html
            }
            warnings.append(.init(code: "enex.mediaNotImported", message: "An ENEX resource reference was retained as a placeholder; resource import is not available in this reader.", kind: .contentLoss))
            let label = ["Resource", node.attribute("type"), node.attribute("hash"), node.attribute("alt")].compactMap { $0 }.joined(separator: " ")
            return "<span>" + Self.escaped("[" + label + "]") + "</span>"
        case "en-crypt":
            warnings.append(.init(code: "enex.encryptedContentRetained", message: "Encrypted ENEX content was retained literally; no decryption was attempted.", kind: .information))
            return "<pre><code>" + Self.escaped(Self.literalXML(node)) + "</code></pre>"
        default: break
        }
        guard Self.elements.contains(node.name) else { return unsupported(node) }
        if ["br", "hr", "img", "col"].contains(node.name), !node.children.isEmpty || !node.text.isEmpty { return unsupported(node) }
        if node.name == "div", let style = node.attribute("style"),
           style.range(of: #"(?:^|;)\s*-{1,2}en-codeblock\s*:\s*true(?:\s*;|\s*$)"#, options: .regularExpression) != nil {
            return "<pre><code>" + Self.escaped(Self.codeText(node)) + "</code></pre>"
        }
        var attributes: [String: String] = [:]
        for key in ["title", "alt", "width", "height", "colspan", "rowspan", "start", "align"] {
            if let value = node.attribute(key) { attributes[key] = value }
        }
        if node.name == "img", let source = node.attribute("src") { attributes["src"] = source }
        if node.name == "a", let target = node.attribute("href") {
            if let noteLinks {
                switch noteLinks.resolve(target, markdownName: markdownName) {
                case .resolved(let path): return "<a href=\"" + Self.escaped(path) + "\">" + (try children(node)) + "</a>"
                case .unavailable(let warning):
                    warnings.append(warning)
                    return (try children(node)) + " (<code>" + Self.escaped(target) + "</code>)"
                case .external: break
                }
            }
            let scheme = URLComponents(string: target)?.scheme?.lowercased()
            if ["http", "https", "mailto"].contains(scheme ?? ""),
               !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                attributes["href"] = target
            } else {
                warnings.append(.init(code: "enex.linkNotResolved", message: "An ENEX link target was retained as text because it cannot be resolved safely in this import.", kind: .approximation))
                return (try children(node)) + " (<code>" + Self.escaped(target) + "</code>)"
            }
        }
        var body = try children(node)
        if let style = node.attribute("style") {
            if style.range(of: #"font-weight\s*:\s*(bold|[6-9]00)"#, options: .regularExpression) != nil { body = "<strong>" + body + "</strong>" }
            if style.range(of: #"font-style\s*:\s*italic"#, options: .regularExpression) != nil { body = "<em>" + body + "</em>" }
            if style.range(of: #"text-decoration\s*:[^;]*line-through"#, options: .regularExpression) != nil { body = "<del>" + body + "</del>" }
        }
        let values = attributes.sorted { $0.key < $1.key }.map { " " + $0.key + "=\"" + Self.escaped($0.value) + "\"" }.joined()
        if ["br", "hr", "img", "col"].contains(node.name) { return "<" + node.name + values + ">" }
        return "<" + node.name + values + ">" + body + "</" + node.name + ">"
    }

    private mutating func unsupported(_ node: ImportXML) -> String {
        warnings.append(.init(code: "enex.unsupportedElementRetained", message: "An unsupported ENML element was retained literally: " + node.name, kind: .approximation))
        return "<pre><code>" + Self.escaped(Self.literalXML(node)) + "</code></pre>"
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func literalXML(_ node: ImportXML) -> String {
        let name = node.namespace.isEmpty ? node.name : "{" + node.namespace + "}" + node.name
        let attributes = node.attributes.sorted { $0.key < $1.key }.map {
            let key = $0.key.hasPrefix("|") ? String($0.key.dropFirst()) : $0.key
            return " " + key + "=\"" + escaped($0.value) + "\""
        }.joined()
        let content = node.content.map { part in switch part { case .text(let value): escaped(value); case .element(let child): literalXML(child) } }.joined()
        return "<" + name + attributes + ">" + content + "</" + name + ">"
    }
    private static func codeText(_ node: ImportXML) -> String {
        node.content.map { part in
            switch part {
            case .text(let value): return value
            case .element(let child):
                if child.name == "br" { return "\n" }
                let value = codeText(child)
                return ["div", "p"].contains(child.name) ? value + "\n" : value
            }
        }.joined()
    }
}
