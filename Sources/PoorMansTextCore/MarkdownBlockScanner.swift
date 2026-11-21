import Foundation

enum MarkdownBlockScanner {
    /// Die Normalisierung schützt Code nach denselben Containerregeln wie die Linkersetzung.
    static func codeLines(in lines: [String]) -> [Bool] {
        var containers = Containers()
        var fencedCode: Fence?
        return lines.map { line in
            if let fence = fencedCode, let candidate = fence.content(in: line) {
                if fence.ends(in: candidate) { fencedCode = nil }
                containers.canStartIndentedCode = true
                return true
            }
            fencedCode = nil
            let context = lineContext(line, containers: &containers)
            if context.isIndentedCode {
                containers.canStartIndentedCode = true
                return true
            }
            if let fence = openingFence(in: context) {
                fencedCode = fence
                containers.canStartIndentedCode = true
                return true
            }
            containers.canStartIndentedCode = context.isBlank || !context.allowsParagraphContinuation
            return false
        }
    }

    struct Containers {
        fileprivate var quoteDepth = 0
        fileprivate var listContentIndents = [Int]()
        var canStartIndentedCode = true
        fileprivate var indentedCodeQuoteDepth: Int?
        fileprivate var indentedCodeListIndent: Int?
        fileprivate var prefixes: [ContainerPrefix] = []

        func hasSameQuoteAndListContext(as other: Containers) -> Bool {
            quoteDepth == other.quoteDepth && listContentIndents == other.listContentIndents
        }
    }

    struct Fence {
        fileprivate let marker: Character
        fileprivate let count: Int
        fileprivate let prefixes: [ContainerPrefix]

        /// Fehlt ein erforderliches Containerpräfix, endet der Fence auch ohne Abschlussmarker.
        func content(in line: String) -> String? {
            containerContent(in: line, prefixes: prefixes)
        }

        func ends(in line: String) -> Bool {
            isClosingFence(line, fence: self)
        }
    }

    fileprivate enum ContainerPrefix {
        case quote
        case indent(Int)
    }

    struct HTMLBlock {
        fileprivate enum Terminator {
            case marker(String, caseInsensitive: Bool)
            case blank
        }

        fileprivate let terminator: Terminator
        fileprivate let prefixes: [ContainerPrefix]
        let canInterruptParagraph: Bool

        func content(in line: String) -> String? {
            containerContent(in: line, prefixes: prefixes)
        }

        func ends(in line: String) -> Bool {
            switch terminator {
            case .marker(let marker, let caseInsensitive):
                return caseInsensitive
                    ? line.range(of: marker, options: .caseInsensitive) != nil
                    : line.contains(marker)
            case .blank:
                return line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    struct LineContext {
        let content: String
        let isIndentedCode: Bool
        let isBlank: Bool
        let allowsParagraphContinuation: Bool
        let startsNewInlineBlock: Bool
        fileprivate var prefixes: [ContainerPrefix] = []
    }

    /// Bestimmt eingerückte GFM-Codeblöcke relativ zu ihren Containern. Vier
    /// Leerzeichen sind am Dokumentrand Code, innerhalb eines Listeneintrags
    /// aber erst vier Spalten hinter dessen Inhaltseinzug. Blockquote-Marker
    /// werden vorher entfernt; dadurch gelten dieselben Regeln auch für `>` und
    /// verschachtelte Listen in Zitaten.
    static func lineContext(
        _ line: String,
        containers: inout Containers
    ) -> LineContext {
        if containers.prefixes.contains(where: { if case .indent = $0 { return true }; return false }),
           containers.prefixes.contains(where: { if case .quote = $0 { return true }; return false }) {
            var start = line.startIndex
            var matched: [ContainerPrefix] = []
            for prefix in containers.prefixes {
                guard let next = containerStart(in: line, from: start, prefix: prefix) else { break }
                start = next
                matched.append(prefix)
            }
            if !matched.isEmpty {
                var nested = Containers()
                nested.canStartIndentedCode = containers.canStartIndentedCode
                nested.indentedCodeQuoteDepth = containers.indentedCodeQuoteDepth
                nested.indentedCodeListIndent = containers.indentedCodeListIndent
                var context = lineContext(String(line[start...]), containers: &nested)
                context.prefixes = matched + context.prefixes
                containers.prefixes = context.prefixes
                return context
            }
        }
        var context = baseLineContext(line, containers: &containers)
        context.prefixes = Array(repeating: .quote, count: containers.quoteDepth)
        if let indent = containers.listContentIndents.last { context.prefixes.append(.indent(indent)) }
        // Listen und Zitate dürfen sich in beliebiger Reihenfolge verschachteln.
        // Der gespeicherte Pfad verhindert, dass ein Listen-Zitat später wie
        // ein Zitat mit nachfolgender Liste behandelt wird.
        if !context.isIndentedCode {
            let candidate = context.content
            var start = candidate.startIndex
            var prefixes = context.prefixes
            var foundQuote = false
            while start < candidate.endIndex {
                let rest = candidate[start...]
                let indent = leadingIndentation(in: rest)
                guard indent.columns <= 3, indent.end < candidate.endIndex else { break }
                if candidate[indent.end] == ">" {
                    prefixes.append(.quote)
                    foundQuote = true
                    start = candidate.index(after: indent.end)
                    if start < candidate.endIndex, candidate[start] == " " || candidate[start] == "\t" { start = candidate.index(after: start) }
                } else if foundQuote, let marker = listMarker(in: rest, at: indent.end) {
                    let padding = followingWhitespace(in: rest, from: marker.end, initialColumn: indent.columns + marker.width)
                    guard padding.end == candidate.endIndex || (1...4).contains(padding.columns) else { break }
                    prefixes.append(.indent(indent.columns + marker.width + max(1, padding.columns)))
                    start = padding.end
                } else { break }
            }
            if foundQuote {
                let inner = String(candidate[start...])
                context = LineContext(content: inner,
                    isIndentedCode: leadingIndentation(in: inner[...]).columns >= 4,
                    isBlank: inner.allSatisfy(\.isWhitespace),
                    allowsParagraphContinuation: !isATXHeading(inner),
                    startsNewInlineBlock: context.startsNewInlineBlock, prefixes: prefixes)
            }
        }
        containers.prefixes = context.prefixes
        return context
    }

    private static func baseLineContext(
        _ line: String,
        containers: inout Containers
    ) -> LineContext {
        let quote = blockquoteContent(in: line)
        let previousQuoteDepth = containers.quoteDepth
        let previousListContentIndents = containers.listContentIndents
        let containerChanged = quote.depth != previousQuoteDepth
        let hadOpenParagraph = !containers.canStartIndentedCode
        // Ein Blockquote-Absatz darf auf einer Folgezeile den `>`-Marker
        // auslassen. Beim Verlassen des Zitats ist der Containerwechsel dann
        // kein neuer Block, solange der vorige Absatz noch fortsetzbar war.
        let continuesLazyBlockquoteParagraph = quote.depth < previousQuoteDepth
            && hadOpenParagraph
        let canUnderlinePreviousParagraph = hadOpenParagraph
            && (!containerChanged || continuesLazyBlockquoteParagraph)
        if containerChanged {
            containers.quoteDepth = quote.depth
            containers.listContentIndents.removeAll()
        }
        let content = line[quote.contentStart...]
        let indentation = leadingIndentation(in: content)
        if indentation.end == content.endIndex {
            return LineContext(
                content: "",
                isIndentedCode: false,
                isBlank: true,
                allowsParagraphContinuation: false,
                startsNewInlineBlock: true
            )
        }

        while let active = containers.listContentIndents.last,
              indentation.columns < active {
            containers.listContentIndents.removeLast()
        }
        let listContainerChanged = containers.listContentIndents != previousListContentIndents
        let baseIndent = containers.listContentIndents.last ?? 0
        let relativeIndent = indentation.columns - baseIndent
        if relativeIndent >= 4 {
            return indentedCodeContext(
                content: String(content[index(after: baseIndent, in: content)...]),
                forced: false,
                containerChangeStartsBlock: containerChanged
                    && !continuesLazyBlockquoteParagraph,
                containers: &containers
            )
        }

        let fenceCandidate = String(content[index(after: baseIndent, in: content)...])
        if relativeIndent <= 3,
           canUnderlinePreviousParagraph,
           isSetextUnderline(fenceCandidate) {
            containers.indentedCodeQuoteDepth = nil
            containers.indentedCodeListIndent = nil
            return LineContext(
                content: fenceCandidate,
                isIndentedCode: false,
                isBlank: false,
                allowsParagraphContinuation: false,
                startsNewInlineBlock: true
            )
        }

        if relativeIndent <= 3, isThematicBreak(fenceCandidate) {
            containers.indentedCodeQuoteDepth = nil
            containers.indentedCodeListIndent = nil
            return LineContext(
                content: fenceCandidate,
                isIndentedCode: false,
                isBlank: false,
                allowsParagraphContinuation: false,
                startsNewInlineBlock: true
            )
        }

        if relativeIndent <= 3,
           let marker = listMarker(in: content, at: indentation.end) {
            // Nur `1.` darf einen laufenden Absatz unterbrechen. Ein `2.` in
            // einem weichen Zeilenumbruch bleibt Absatztext und darf einen
            // offenen Code-Span daher nicht künstlich beenden.
            if hadOpenParagraph, !containerChanged, !listContainerChanged,
               let orderedStart = marker.orderedStart,
               orderedStart != 1 {
                containers.indentedCodeQuoteDepth = nil
                containers.indentedCodeListIndent = nil
                return LineContext(
                    content: fenceCandidate,
                    isIndentedCode: false,
                    isBlank: false,
                    allowsParagraphContinuation: true,
                    startsNewInlineBlock: false
                )
            }
            return listContext(
                content: content,
                marker: marker,
                markerColumn: indentation.columns,
                fallbackCandidate: fenceCandidate,
                containerChanged: containerChanged,
                containers: &containers
            )
        }

        containers.indentedCodeQuoteDepth = nil
        containers.indentedCodeListIndent = nil
        return LineContext(
            content: fenceCandidate,
            isIndentedCode: false,
            isBlank: false,
            allowsParagraphContinuation: !isATXHeading(fenceCandidate)
                && !(canUnderlinePreviousParagraph && isSetextUnderline(fenceCandidate)),
            startsNewInlineBlock: (containerChanged && !continuesLazyBlockquoteParagraph)
                || isATXHeading(fenceCandidate)
                || (canUnderlinePreviousParagraph && isSetextUnderline(fenceCandidate))
        )
    }

    /// Verarbeitet alle direkt aufeinanderfolgenden Listenmarker. Bei
    /// `- - ~~~` gehört der Fence zum inneren Eintrag; nach nur einem Marker
    /// sähe derselbe Text wie gewöhnlicher Absatzinhalt aus.
    private static func listContext(
        content: Substring,
        marker firstMarker: (end: String.Index, width: Int, orderedStart: Int?),
        markerColumn firstMarkerColumn: Int,
        fallbackCandidate: String,
        containerChanged: Bool,
        containers: inout Containers
    ) -> LineContext {
        var marker = firstMarker
        var markerColumn = firstMarkerColumn
        while true {
            let padding = followingWhitespace(
                in: content,
                from: marker.end,
                initialColumn: markerColumn + marker.width
            )
            let hasContent = padding.end < content.endIndex
            guard !hasContent || padding.columns > 0 else {
                containers.indentedCodeQuoteDepth = nil
                containers.indentedCodeListIndent = nil
                return LineContext(
                    content: fallbackCandidate,
                    isIndentedCode: false,
                    isBlank: false,
                    allowsParagraphContinuation: true,
                    startsNewInlineBlock: false
                )
            }
            let effectivePadding = hasContent && padding.columns > 4 ? 1 : max(1, padding.columns)
            let contentIndent = markerColumn + marker.width + effectivePadding
            containers.listContentIndents.append(contentIndent)
            let isIndentedCandidate = hasContent && padding.columns > 4
            if isIndentedCandidate {
                return indentedCodeContext(
                    content: String(content[padding.end...]),
                    forced: true,
                    containerChangeStartsBlock: containerChanged,
                    containers: &containers
                )
            }
            if hasContent,
               let nestedMarker = listMarker(in: content, at: padding.end) {
                let nestedPadding = followingWhitespace(
                    in: content,
                    from: nestedMarker.end,
                    initialColumn: contentIndent + nestedMarker.width
                )
                if nestedPadding.end == content.endIndex || nestedPadding.columns > 0 {
                    marker = nestedMarker
                    markerColumn = contentIndent
                    continue
                }
            }
            containers.indentedCodeQuoteDepth = nil
            containers.indentedCodeListIndent = nil
            return LineContext(
                content: hasContent ? String(content[padding.end...]) : "",
                isIndentedCode: false,
                isBlank: false,
                allowsParagraphContinuation: !isATXHeading(
                    hasContent ? String(content[padding.end...]) : ""
                ),
                startsNewInlineBlock: true
            )
        }
    }

    private static func indentedCodeContext(
        content: String,
        forced: Bool,
        containerChangeStartsBlock: Bool,
        containers: inout Containers
    ) -> LineContext {
        let listIndent = containers.listContentIndents.last
        let continuesCode = containers.indentedCodeQuoteDepth == containers.quoteDepth
            && containers.indentedCodeListIndent == listIndent
        let isCode = forced || containerChangeStartsBlock
            || containers.canStartIndentedCode || continuesCode
        if isCode {
            containers.indentedCodeQuoteDepth = containers.quoteDepth
            containers.indentedCodeListIndent = listIndent
        } else {
            containers.indentedCodeQuoteDepth = nil
            containers.indentedCodeListIndent = nil
        }
        return LineContext(
            content: content,
            isIndentedCode: isCode,
            isBlank: false,
            allowsParagraphContinuation: false,
            startsNewInlineBlock: isCode
        )
    }

    private static func isATXHeading(_ line: String) -> Bool {
        let content = line.drop(while: { $0 == " " })
        guard line.distance(from: line.startIndex, to: content.startIndex) <= 3,
              content.first == "#" else {
            return false
        }
        let end = content.firstIndex(where: { $0 != "#" }) ?? content.endIndex
        let count = content.distance(from: content.startIndex, to: end)
        guard (1...6).contains(count) else { return false }
        return end == content.endIndex || content[end].isWhitespace
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        let content = line.drop(while: { $0 == " " })
        guard line.distance(from: line.startIndex, to: content.startIndex) <= 3 else {
            return false
        }
        let marker = content.first
        guard marker == "=" || marker == "-" else { return false }
        let underline = content.prefix(while: { $0 == marker })
        let remainder = content[underline.endIndex...]
        return !underline.isEmpty && remainder.allSatisfy(\.isWhitespace)
    }

    private static func index(after columns: Int, in text: Substring) -> String.Index {
        var index = text.startIndex
        var currentColumn = 0
        while index < text.endIndex, currentColumn < columns {
            if text[index] == " " {
                currentColumn += 1
            } else if text[index] == "\t" {
                currentColumn += 4 - currentColumn % 4
            } else {
                break
            }
            index = text.index(after: index)
        }
        return index
    }

    private static func blockquoteContent(
        in line: String
    ) -> (contentStart: String.Index, depth: Int) {
        var start = line.startIndex
        var depth = 0
        while start < line.endIndex {
            var candidate = start
            var spaces = 0
            while candidate < line.endIndex, line[candidate] == " ", spaces < 3 {
                spaces += 1
                candidate = line.index(after: candidate)
            }
            guard candidate < line.endIndex, line[candidate] == ">" else { break }
            candidate = line.index(after: candidate)
            if candidate < line.endIndex,
               line[candidate] == " " || line[candidate] == "\t" {
                candidate = line.index(after: candidate)
            }
            start = candidate
            depth += 1
        }
        return (start, depth)
    }

    static func leadingIndentation(
        in text: Substring
    ) -> (columns: Int, end: String.Index) {
        followingWhitespace(in: text, from: text.startIndex, initialColumn: 0)
    }

    private static func followingWhitespace(
        in text: Substring,
        from start: String.Index,
        initialColumn: Int
    ) -> (columns: Int, end: String.Index) {
        var index = start
        var column = initialColumn
        while index < text.endIndex {
            if text[index] == " " {
                column += 1
            } else if text[index] == "\t" {
                column += 4 - column % 4
            } else {
                break
            }
            index = text.index(after: index)
        }
        return (column - initialColumn, index)
    }

    private static func listMarker(
        in text: Substring,
        at start: String.Index
    ) -> (end: String.Index, width: Int, orderedStart: Int?)? {
        guard start < text.endIndex else { return nil }
        if "-+*".contains(text[start]) {
            return (text.index(after: start), 1, nil)
        }
        var end = start
        var digits = 0
        while end < text.endIndex, text[end].isNumber, digits < 9 {
            digits += 1
            end = text.index(after: end)
        }
        guard digits > 0, end < text.endIndex,
              text[end] == "." || text[end] == ")" else {
            return nil
        }
        return (
            text.index(after: end),
            digits + 1,
            Int(text[start..<end])
        )
    }

    static func openingFence(in context: LineContext) -> Fence? {
        guard let fence = openingFence(context.content) else { return nil }
        return Fence(marker: fence.marker, count: fence.count, prefixes: context.prefixes)
    }

    static func openingHTMLBlock(in context: LineContext) -> HTMLBlock? {
        guard let opening = openingHTMLBlock(context.content) else { return nil }
        return HTMLBlock(terminator: opening.terminator, prefixes: context.prefixes,
                         canInterruptParagraph: opening.canInterruptParagraph)
    }

    private static func containerContent(in line: String, prefixes: [ContainerPrefix]) -> String? {
        var start = line.startIndex
        for prefix in prefixes {
            if case .indent = prefix, line[start...].allSatisfy(\.isWhitespace) { return "" }
            guard let next = containerStart(in: line, from: start, prefix: prefix) else { return nil }
            start = next
        }
        return String(line[start...])
    }

    private static func containerStart(in line: String, from start: String.Index, prefix: ContainerPrefix) -> String.Index? {
        switch prefix {
        case .quote:
            var marker = start
            var spaces = 0
            while marker < line.endIndex, line[marker] == " ", spaces < 3 {
                marker = line.index(after: marker); spaces += 1
            }
            guard marker < line.endIndex, line[marker] == ">" else { return nil }
            var next = line.index(after: marker)
            if next < line.endIndex, line[next] == " " || line[next] == "\t" { next = line.index(after: next) }
            return next
        case .indent(let columns):
            let content = line[start...]
            guard leadingIndentation(in: content).columns >= columns else { return nil }
            return index(after: columns, in: content)
        }
    }

    private static func openingFence(_ line: String) -> (marker: Character, count: Int)? {
        let content = line.drop(while: { $0 == " " })
        guard line.distance(from: line.startIndex, to: content.startIndex) <= 3,
              let marker = content.first,
              marker == "`" || marker == "~" else {
            return nil
        }
        let end = content.firstIndex(where: { $0 != marker }) ?? content.endIndex
        let count = content.distance(from: content.startIndex, to: end)
        // Bei Backtick-Fences verbietet GFM einen weiteren Backtick im Info-Text.
        // Sonst ist die Zeile gewöhnlicher Absatzinhalt, kein Codeblock-Anfang.
        if marker == "`", content[end...].contains("`") {
            return nil
        }
        return count >= 3 ? (marker, count) : nil
    }

    /// Erkennt die zustandsbehafteten GFM-HTML-Blöcke, deren Inhalt nicht als
    /// Markdown geparst wird. Rohtext-Tags, Kommentare, Verarbeitungsanweisungen,
    /// Deklarationen und CDATA enden an ihrem Marker; die benannten Block-Tags
    /// enden an der nächsten Leerzeile.
    private static func openingHTMLBlock(
        _ line: String
    ) -> (terminator: HTMLBlock.Terminator, canInterruptParagraph: Bool)? {
        let indentation = line.prefix(while: { $0 == " " })
        guard indentation.count <= 3 else { return nil }
        let content = line.dropFirst(indentation.count)
        guard !content.isEmpty else { return nil }
        let text = String(content)
        let lower = text.lowercased()

        if lower.hasPrefix("<!--") {
            return (.marker("-->", caseInsensitive: false), true)
        }
        if lower.hasPrefix("<?") {
            return (.marker("?>", caseInsensitive: false), true)
        }
        if text.hasPrefix("<![CDATA[") {
            return (.marker("]]>", caseInsensitive: false), true)
        }
        if text.hasPrefix("<!"),
           let declarationStart = text.dropFirst(2).first,
           declarationStart.isASCII,
           declarationStart >= "A", declarationStart <= "Z" {
            return (.marker(">", caseInsensitive: false), true)
        }

        for tag in ["script", "pre", "style", "textarea"] {
            guard lower.hasPrefix("<\(tag)") else { continue }
            let boundary = lower.index(lower.startIndex, offsetBy: tag.count + 1)
            guard boundary == lower.endIndex
                    || lower[boundary].isWhitespace
                    || lower[boundary] == ">" else { continue }
            return (.marker("</\(tag)>", caseInsensitive: true), true)
        }

        let blockTags: Set<String> = [
            "address", "article", "aside", "base", "basefont", "blockquote", "body",
            "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
            "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
            "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
            "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu",
            "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param",
            "search", "section", "summary", "table", "tbody", "td", "tfoot", "th",
            "thead", "title", "tr", "track", "ul",
        ]
        guard lower.first == "<" else { return nil }
        var tagStart = lower.index(after: lower.startIndex)
        if tagStart < lower.endIndex, lower[tagStart] == "/" {
            tagStart = lower.index(after: tagStart)
        }
        let tagEnd = lower[tagStart...].firstIndex {
            !$0.isLetter && !$0.isNumber
        } ?? lower.endIndex
        if tagStart < tagEnd,
           blockTags.contains(String(lower[tagStart..<tagEnd])) {
            guard tagEnd == lower.endIndex
                    || lower[tagEnd].isWhitespace
                    || lower[tagEnd] == ">"
                    || (lower[tagEnd] == "/"
                        && lower.index(after: tagEnd) < lower.endIndex
                        && lower[lower.index(after: tagEnd)] == ">") else {
                return nil
            }
            return (.blank, true)
        }

        // GFM-Typ 7: ein vollständiges gewöhnliches Open- oder Close-Tag. Es
        // darf einen laufenden Absatz nicht unterbrechen und endet wie Typ 6 an
        // der nächsten Leerzeile.
        let genericOpenTagPattern = #"^<[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:[^\s\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*\s*/?>\s*$"#
        let genericClosingTagPattern = #"^</[A-Za-z][A-Za-z0-9-]*\s*>\s*$"#
        if text.range(of: genericOpenTagPattern, options: .regularExpression) != nil
            || text.range(of: genericClosingTagPattern, options: .regularExpression) != nil {
            return (.blank, false)
        }
        return nil
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        // `markers` ist die Zeile ohne Leerraum. Sind alle diese Zeichen
        // derselbe Marker, besteht die Zeile zwangsläufig nur aus Marker und
        // Leerraum — eine zweite Prüfung über die ganze Zeile wäre wirkungslos.
        let markers = line.filter { character in
            character != " " && character != "\t"
        }
        guard markers.count >= 3,
              let marker = markers.first,
              marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return markers.allSatisfy { $0 == marker }
    }

    private static func isClosingFence(
        _ line: String,
        fence: Fence
    ) -> Bool {
        let content = line.drop(while: { $0 == " " })
        guard line.distance(from: line.startIndex, to: content.startIndex) <= 3,
              content.first == fence.marker else {
            return false
        }
        let end = content.firstIndex(where: { $0 != fence.marker }) ?? content.endIndex
        return content.distance(from: content.startIndex, to: end) >= fence.count
            && content[end...].allSatisfy(\.isWhitespace)
    }
}
