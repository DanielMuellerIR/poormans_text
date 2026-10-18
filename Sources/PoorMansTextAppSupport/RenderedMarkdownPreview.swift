import Foundation
import Markdown
import PoorMansTextCore

public struct PreviewAnchor: Sendable, Equatable {
    public let id: String
    public let utf8Offset: Int
    public let utf8Length: Int
}

public struct RenderedMarkdownPreview: Sendable {
    public let html: String
    public let anchors: [PreviewAnchor]
    public let limited: Bool
    public let hasLiteralHTML: Bool
    public let unavailableImageCount: Int
    public let hasUnsupportedMarkup: Bool

    public func anchor(for range: ConversionTextRange) -> PreviewAnchor? {
        guard range.utf8Offset >= 0, range.utf8Length >= 0,
              range.utf8Length <= Int.max - range.utf8Offset else { return nil }
        let end = range.utf8Offset + range.utf8Length
        if let containing = anchors.filter({ $0.utf8Offset <= range.utf8Offset && ($0.utf8Offset + $0.utf8Length > range.utf8Offset || ($0.utf8Length == 0 && $0.utf8Offset == range.utf8Offset)) }).min(by: { $0.utf8Length < $1.utf8Length }) {
            return containing
        }
        return anchors.first { $0.utf8Offset >= range.utf8Offset && $0.utf8Offset < end }
    }

    public static func render(_ text: String, assets: PreviewAssets?, imageUnavailable: String = "Image unavailable in preview", limitMessage: String = "Rendered preview limited", metadataTitle: String = "Document metadata", language: String = "en") -> Self {
        var prefix = Data(text.utf8.prefix(MarkdownPreview.byteLimit))
        for _ in 0..<3 where String(data: prefix, encoding: .utf8) == nil { if !prefix.isEmpty { prefix.removeLast() } }
        let input = String(decoding: prefix, as: UTF8.self)
        let metadata = frontmatter(in: input)
        let start = metadata?.upperBound ?? input.startIndex
        let offset = input.utf8.distance(from: input.startIndex, to: start)
        var renderer = Renderer(source: input, parseOffset: offset, assets: assets, imageUnavailable: imageUnavailable)
        if let metadata {
            renderer.append("<details class=\"metadata\"><summary>\(escape(metadataTitle))</summary><pre>\(escape(String(input[metadata])))</pre></details>")
        }
        renderer.render(Document(parsing: String(input[start...])), depth: 0)
        let limited = renderer.limited || input != text
        let notice = limited ? "<p class=\"notice\">\(escape(limitMessage))</p>" : ""
        let html = """
        <!doctype html><html lang="\(language == "de" ? "de" : "en")"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src pmt-preview:; style-src 'unsafe-inline'; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <style>\(styles)</style></head><body><main>\(renderer.body)\(notice)</main></body></html>
        """
        return Self(html: html, anchors: renderer.anchors, limited: limited, hasLiteralHTML: renderer.hasLiteralHTML,
                    unavailableImageCount: renderer.unavailableImages, hasUnsupportedMarkup: renderer.unsupported)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func frontmatter(in text: String) -> Range<String.Index>? {
        let opening = text.hasPrefix("---\r\n") ? "---\r\n" : "---\n"
        guard text.hasPrefix(opening) else { return nil }
        let prefix = text.prefix(16_384)
        let begin = text.index(text.startIndex, offsetBy: opening.count)
        let delimiter = text.hasPrefix("---\r\n") ? "\r\n---\r\n" : "\n---\n"
        guard let end = text.range(of: delimiter, range: begin..<prefix.endIndex),
              text[begin..<end.lowerBound].range(of: #"(?m)^[A-Za-z][A-Za-z0-9_-]*:"#, options: .regularExpression) != nil else { return nil }
        return text.startIndex..<end.upperBound
    }

    private struct Renderer {
        let source: String
        let assets: PreviewAssets?
        let imageUnavailable: String
        let lineStarts: [Int]
        let sourceBytes: [UInt8]
        var body = ""
        var bytes = 0
        var nodes = 0
        var anchors: [PreviewAnchor] = []
        var limited = false
        var hasLiteralHTML = false
        var unavailableImages = 0
        var unsupported = false
        var images = Set<URL>()
        var inTableHead = false
        var column = 0
        var alignments: [Table.ColumnAlignment?] = []
        var anchorCounter = 0

        init(source: String, parseOffset: Int, assets: PreviewAssets?, imageUnavailable: String) {
            self.source = source; self.assets = assets; self.imageUnavailable = imageUnavailable
            sourceBytes = Array(source.utf8)
            var starts = [parseOffset]
            for (index, byte) in source.utf8.enumerated() where index >= parseOffset && byte == 10 { starts.append(index + 1) }
            lineStarts = starts
        }

        @discardableResult mutating func append(_ text: String) -> Bool {
            guard !limited else { return false }
            guard text.utf8.count <= 1_048_576 - bytes else { limited = true; return false }
            bytes += text.utf8.count; body += text
            return true
        }
        mutating func close(_ tag: String) { body += "</\(tag)>" }
        func offset(_ location: SourceLocation) -> Int? {
            guard location.line > 0, location.line <= lineStarts.count, location.column > 0 else { return nil }
            let offset = lineStarts[location.line - 1] + location.column - 1
            let lineEnd = location.line < lineStarts.count ? lineStarts[location.line] - 1 : sourceBytes.count
            guard offset <= lineEnd, offset == sourceBytes.count || sourceBytes[offset] & 0xC0 != 0x80 else { return nil }
            return offset
        }
        mutating func start(_ tag: String, node: any Markup, attributes: String = "") -> String? {
            var anchor: PreviewAnchor?
            if let range = node.range, let lower = offset(range.lowerBound), let upper = offset(range.upperBound), upper >= lower {
                anchor = PreviewAnchor(id: "pmt-\(anchorCounter)", utf8Offset: lower, utf8Length: upper - lower)
            }
            guard append("<\(tag)\(anchor.map { " id=\"\($0.id)\"" } ?? "")\(attributes)>") else { return nil }
            if let anchor { anchors.append(anchor); anchorCounter += 1 }
            return anchor?.id ?? ""
        }
        mutating func end(_ tag: String, anchor: String) {
            close(tag)
            if limited, !anchor.isEmpty { anchors.removeAll { $0.id == anchor } }
        }
        mutating func wrap(_ tag: String, node: any Markup, depth: Int, attributes: String = "") {
            guard let anchor = start(tag, node: node, attributes: attributes) else { return }
            renderChildren(node, depth: depth)
            end(tag, anchor: anchor)
        }
        mutating func renderChildren(_ node: any Markup, depth: Int) {
            // Nachbarn im selben Durchlauf mitgeben: child(at:) berechnet im
            // Markdown-Paket IDs über alle vorherigen Geschwister und ist O(n).
            var iterator = node.children.makeIterator()
            var previous: (any Markup)?
            var current = iterator.next()
            while !limited, let child = current {
                let next = iterator.next()
                render(child, depth: depth + 1, previousSibling: previous, nextSibling: next)
                previous = child; current = next
            }
        }
        mutating func render(_ node: any Markup, depth: Int, previousSibling: (any Markup)? = nil, nextSibling: (any Markup)? = nil) {
            guard !limited else { return }
            nodes += 1
            guard nodes <= 50_000, depth <= 64 else { limited = true; return }
            switch node {
            case is Document:
                renderChildren(node, depth: depth)
            case let text as Markdown.Text: append(escape(text.string))
            case is SoftBreak: append("\n")
            case is LineBreak: append("<br>")
            case let code as InlineCode: append("<code>\(escape(code.code))</code>")
            case let code as CodeBlock:
                guard let anchor = start("pre", node: node) else { return }
                if append("<code>") { append(escape(code.code)); close("code") }
                end("pre", anchor: anchor)
            case let heading as Heading: wrap("h\(min(6, max(1, heading.level)))", node: node, depth: depth)
            case is Paragraph: wrap("p", node: node, depth: depth)
            case is BlockQuote: wrap("blockquote", node: node, depth: depth)
            case is UnorderedList: wrap("ul", node: node, depth: depth)
            case let list as OrderedList: wrap("ol", node: node, depth: depth, attributes: " start=\"\(list.startIndex)\"")
            case let item as ListItem:
                guard let anchor = start("li", node: node) else { return }
                if let checkbox = item.checkbox { append(checkbox == .checked ? "<span class=\"checkbox\">☑</span> " : "<span class=\"checkbox\">☐</span> ") }
                renderChildren(node, depth: depth); end("li", anchor: anchor)
            case is Emphasis: wrap("em", node: node, depth: depth)
            case is Strong: wrap("strong", node: node, depth: depth)
            case is Strikethrough: wrap("del", node: node, depth: depth)
            case is ThematicBreak: _ = start("hr", node: node)
            case let html as HTMLBlock:
                if let id = generatedImportAnchor(html.rawHTML.trimmingCharacters(in: .newlines)) {
                    if let anchor = start("span", node: node) { append("<span id=\"\(id)\"></span>"); end("span", anchor: anchor) }
                    return
                }
                hasLiteralHTML = true
                guard let anchor = start("pre", node: node, attributes: " class=\"literal-html\"") else { return }
                append(escape(html.rawHTML)); end("pre", anchor: anchor)
            case let html as InlineHTML:
                if ["<br>", "<br/>", "<br />"].contains(html.rawHTML.lowercased()) { append("<br>"); return }
                if let id = generatedImportAnchor(html.rawHTML + "</a>"),
                   (nextSibling as? InlineHTML)?.rawHTML == "</a>" {
                    if let anchor = start("span", node: node) { append("<span id=\"\(id)\"></span>"); end("span", anchor: anchor) }
                    return
                }
                if html.rawHTML == "</a>", let previous = previousSibling as? InlineHTML,
                   generatedImportAnchor(previous.rawHTML + "</a>") != nil { return }
                hasLiteralHTML = true; append(escape(html.rawHTML))
            case let image as Markdown.Image:
                let alt = plainText(image, depth: 0)
                if let target = image.source, let url = assets?.url(for: target), images.contains(url) || images.count < 64 {
                    images.insert(url)
                    _ = start("img", node: node, attributes: " src=\"\(escape(url.absoluteString))\" alt=\"\(escape(alt))\" loading=\"lazy\"")
                } else {
                    unavailableImages += 1
                    guard let anchor = start("span", node: node, attributes: " class=\"missing-image\"") else { return }
                    append(escape(imageUnavailable) + (alt.isEmpty ? "" : ": " + escape(alt)))
                    end("span", anchor: anchor)
                }
            case let link as Link:
                wrap("span", node: node, depth: depth, attributes: " class=\"preview-link\" title=\"\(escape(link.destination ?? ""))\"")
            case let table as Table:
                let previous = alignments; alignments = table.columnAlignments
                guard let anchor = start("div", node: node, attributes: " class=\"table-wrap\"") else { return }
                guard append("<table>") else { end("div", anchor: anchor); return }
                renderChildren(node, depth: depth)
                close("table"); end("div", anchor: anchor); alignments = previous
            case is Table.Head:
                inTableHead = true; column = 0
                guard append("<thead><tr>") else { inTableHead = false; return }
                renderChildren(node, depth: depth)
                close("tr"); close("thead"); inTableHead = false
            case is Table.Body: wrap("tbody", node: node, depth: depth)
            case is Table.Row: column = 0; wrap("tr", node: node, depth: depth)
            case is Table.Cell:
                let alignment = column < alignments.count ? alignments[column] : nil
                let value = alignment == .right ? "right" : alignment == .center ? "center" : "left"
                column += 1
                wrap(inTableHead ? "th" : "td", node: node, depth: depth, attributes: " style=\"text-align:\(value)\"")
            default:
                unsupported = true
                if let range = node.range, let start = offset(range.lowerBound), let end = offset(range.upperBound), end >= start,
                   let anchor = self.start("span", node: node, attributes: " class=\"unsupported\"") {
                    append(escape(String(decoding: sourceBytes[start..<end], as: UTF8.self)))
                    self.end("span", anchor: anchor)
                } else {
                    renderChildren(node, depth: depth)
                }
            }
        }
        // Nur exakt leere, von den Dokumentimportern erzeugbare Anker.
        func generatedImportAnchor(_ raw: String) -> String? {
            guard raw.utf8.count <= 128,
                  raw.range(of: #"^<a id="pmt-(?:epub-chapter-[1-9][0-9]*(?:-anchor-[1-9][0-9]*)?|slide-[1-9][0-9]*|pdf-page-[1-9][0-9]*)"></a>$"#, options: .regularExpression) != nil else { return nil }
            return String(raw.dropFirst(7).dropLast(6))
        }
        func plainText(_ node: any Markup, depth: Int) -> String {
            guard depth < 64 else { return "" }
            if let text = node as? Markdown.Text { return text.string }
            if let code = node as? InlineCode { return code.code }
            return String(node.children.map { plainText($0, depth: depth + 1) }.joined().prefix(1024))
        }
    }

    private static let styles = """
    :root {color-scheme:light dark; --border:#d8d8dd; --subtle:#f4f4f6; --muted:#606068;}
    @media(prefers-color-scheme:dark) {:root {--border:#505056; --subtle:#28282c; --muted:#b8b8c0;}}
    body {margin:0; background:Canvas; color:CanvasText; font:14px/1.55 -apple-system,BlinkMacSystemFont,sans-serif; overflow-wrap:anywhere;}
    main {padding:16px 20px 24px;} h1,h2,h3,h4 {line-height:1.25; margin:1.2em 0 .5em;} h1 {font-size:24px;} h2 {font-size:20px;} h3 {font-size:17px;} h4,h5,h6 {font-size:15px;}
    p {margin:.7em 0;} ul,ol {padding-left:1.8em;} li>p {margin:.3em 0;} blockquote {margin:1em 0; padding:.1em 1em; border-left:3px solid var(--border); color:var(--muted);}
    pre,code {font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px;} pre {padding:12px; background:var(--subtle); border-radius:7px; overflow:auto; white-space:pre; overflow-wrap:normal;}
    :not(pre)>code {padding:2px 4px; border-radius:4px; background:var(--subtle);} .table-wrap {overflow-x:auto; margin:1em 0;} table {border-collapse:collapse; font-size:13px;} th,td {border:1px solid var(--border); padding:6px 10px; min-width:40px;} th {background:var(--subtle); font-weight:600;}
    img {display:block; max-width:100%; max-height:900px; width:auto; height:auto; margin:1em 0;} .preview-link {color:LinkText; text-decoration:underline; cursor:text;}
    .missing-image,.notice {display:block; padding:8px 10px; background:var(--subtle); border:1px solid var(--border); border-radius:6px; color:var(--muted); font-size:12px;} .literal-html,.unsupported {white-space:pre-wrap;} hr {border:0; border-top:1px solid var(--border); margin:1.2em 0;}
    details.metadata {font-size:12px; color:var(--muted); border-bottom:1px solid var(--border); padding-bottom:8px;} summary {cursor:default;}
    """
}
