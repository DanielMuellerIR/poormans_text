import Foundation

/// Schreibt Asset-Ziele in echten Markdown-Links um und lässt wörtlichen Code
/// unangetastet. Ein bloßes Suchen nach `](ziel)` kann denselben Text in einem
/// Code-Span, einem Codeblock oder hinter einem Escape treffen.
enum MarkdownLinkTargetRewriter {
    static func replacing(in markdown: String, from oldPath: String, to newPath: String) -> String {
        var result = ""
        var fencedCode: MarkdownFenceState?
        var htmlBlock: MarkdownHTMLBlockState?
        var inlineCodeTicks: Int?
        var bracketDepth = 0
        var containers = MarkdownContainerState()
        var inlineBlockEnd: String.Index?
        let backtickIndex = BacktickRunIndex(markdown)

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let fence = fencedCode,
               let fenceCandidate = fenceContent(in: text, fence: fence) {
                result += text
                if isClosingFence(fenceCandidate, fence: (fence.marker, fence.count)) {
                    fencedCode = nil
                }
                containers.canStartIndentedCode = true
                if line.endIndex != markdown[...].endIndex {
                    result += "\n"
                }
                continue
            }
            // Ein Fence endet mit seinem Blockquote- oder Listeneintrag, auch
            // wenn kein schließender Marker mehr im Container stand.
            fencedCode = nil
            if let activeHTMLBlock = htmlBlock,
               let htmlCandidate = htmlContent(in: text, block: activeHTMLBlock) {
                result += text
                if activeHTMLBlock.ends(in: htmlCandidate) {
                    htmlBlock = nil
                }
                inlineCodeTicks = nil
                bracketDepth = 0
                inlineBlockEnd = nil
                containers.canStartIndentedCode = true
                if line.endIndex != markdown[...].endIndex {
                    result += "\n"
                }
                continue
            }
            if htmlBlock != nil {
                // Wie ein Fence endet auch ein HTML-Block mit seinem Zitat-
                // oder Listeneintrag. Die aktuelle Zeile gehört bereits zum
                // äußeren Container und wird deshalb normal verarbeitet.
                htmlBlock = nil
            }
            let paragraphWasOpen = !containers.canStartIndentedCode
            let previousQuoteDepth = containers.quoteDepth
            let previousListContentIndents = containers.listContentIndents
            let context = lineContext(text, containers: &containers)
            let markdownContainerChanged = previousQuoteDepth != containers.quoteDepth
                || previousListContentIndents != containers.listContentIndents
            if !context.isIndentedCode,
               let openingHTML = openingHTMLBlock(context.fenceCandidate),
               openingHTML.canInterruptParagraph || !paragraphWasOpen
                    || context.startsNewInlineBlock || markdownContainerChanged {
                result += text
                let state = MarkdownHTMLBlockState(
                    terminator: openingHTML.terminator,
                    quoteDepth: containers.quoteDepth,
                    listContentIndent: containers.listContentIndents.last
                )
                if !state.ends(in: context.fenceCandidate) {
                    htmlBlock = state
                }
                inlineCodeTicks = nil
                bracketDepth = 0
                inlineBlockEnd = nil
                containers.canStartIndentedCode = true
                if line.endIndex != markdown[...].endIndex {
                    result += "\n"
                }
                continue
            }
            if context.isBlank || context.startsNewInlineBlock
                || openingFence(context.fenceCandidate) != nil {
                // Inline-Konstrukte enden an der Markdown-Blockgrenze. Ein
                // Backtick in einem späteren Block darf daher weder einen
                // Code-Span schließen noch einen offenen Linktext fortsetzen.
                inlineCodeTicks = nil
                bracketDepth = 0
                inlineBlockEnd = nil
            }
            if context.isIndentedCode {
                result += text
                containers.canStartIndentedCode = true
            } else if inlineCodeTicks == nil,
                      let fence = openingFence(context.fenceCandidate) {
                result += text
                fencedCode = MarkdownFenceState(
                    marker: fence.marker,
                    count: fence.count,
                    quoteDepth: containers.quoteDepth,
                    listContentIndent: containers.listContentIndents.last
                )
                containers.canStartIndentedCode = true
            } else {
                var lookaheadContainers = containers
                lookaheadContainers.canStartIndentedCode = context.isBlank
                    || !context.allowsParagraphContinuation
                if inlineBlockEnd == nil {
                    inlineBlockEnd = context.allowsParagraphContinuation
                        ? followingInlineBlockEnd(
                            after: line,
                            in: markdown,
                            containers: lookaheadContainers
                        )
                        : line.endIndex
                }
                result += rewriteInline(
                    text,
                    in: markdown,
                    sourceLineStart: line.startIndex,
                    inlineBlockEnd: inlineBlockEnd ?? line.endIndex,
                    backtickIndex: backtickIndex,
                    from: oldPath,
                    to: newPath,
                    inlineCodeTicks: &inlineCodeTicks,
                    bracketDepth: &bracketDepth
                )
                containers.canStartIndentedCode = context.isBlank
                    || !context.allowsParagraphContinuation
            }
            if line.endIndex != markdown[...].endIndex {
                result += "\n"
            }
        }
        return result
    }

    /// Liefert nur den Rest des aktuellen Absatzes. Code-Spans dürfen zwar
    /// weiche Zeilenumbrüche enthalten, aber keine Markdown-Blockgrenze wie
    /// Leerzeile, Überschrift, Liste, Zitatwechsel oder Fence überqueren.
    private static func followingInlineBlockEnd(
        after line: Substring,
        in markdown: String,
        containers: MarkdownContainerState
    ) -> String.Index {
        let following = markdown[line.endIndex...]
        guard !following.isEmpty else { return following.endIndex }

        var lookaheadContainers = containers
        var lineStart = following.startIndex
        if following[lineStart] == "\n" {
            lineStart = following.index(after: lineStart)
        }
        while lineStart < following.endIndex {
            let lineEnd = following[lineStart...].firstIndex(of: "\n")
                ?? following.endIndex
            let candidate = following[lineStart..<lineEnd]
            let previousQuoteDepth = lookaheadContainers.quoteDepth
            let previousListContentIndents = lookaheadContainers.listContentIndents
            let context = lineContext(String(candidate), containers: &lookaheadContainers)
            let markdownContainerChanged = previousQuoteDepth != lookaheadContainers.quoteDepth
                || previousListContentIndents != lookaheadContainers.listContentIndents
            let openingHTML = openingHTMLBlock(context.fenceCandidate)
            let interruptsWithHTML = !context.isIndentedCode
                && (openingHTML?.canInterruptParagraph == true
                    || (openingHTML != nil && markdownContainerChanged))
            if context.isBlank || context.startsNewInlineBlock
                || openingFence(context.fenceCandidate) != nil
                || interruptsWithHTML {
                return lineStart
            }
            lookaheadContainers.canStartIndentedCode = context.isBlank
                || !context.allowsParagraphContinuation
            guard lineEnd < following.endIndex else { break }
            lineStart = following.index(after: lineEnd)
        }
        return following.endIndex
    }

    /// Indexiert jeden Backtick-Lauf einmal. Eine binäre Suche beantwortet
    /// danach für jeden möglichen Öffner, ob vor der Absatzgrenze ein gleich
    /// langer Abschluss folgt; kein Absatzrest wird pro Zeile erneut gescannt.
    private struct BacktickRunIndex {
        private let startsByLength: [Int: [String.Index]]

        init(_ markdown: String) {
            var starts = [Int: [String.Index]]()
            var index = markdown.startIndex
            while index < markdown.endIndex {
                guard markdown[index] == "`" else {
                    index = markdown.index(after: index)
                    continue
                }
                let end = markdown[index...].firstIndex(where: { $0 != "`" })
                    ?? markdown.endIndex
                starts[markdown.distance(from: index, to: end), default: []].append(index)
                index = end
            }
            startsByLength = starts
        }

        func hasRun(ofLength length: Int, after start: String.Index, before end: String.Index) -> Bool {
            guard let starts = startsByLength[length] else { return false }
            var lower = 0
            var upper = starts.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if starts[middle] < start {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower < starts.count && starts[lower] < end
        }
    }

    private struct MarkdownContainerState {
        var quoteDepth = 0
        var listContentIndents = [Int]()
        var canStartIndentedCode = true
        var indentedCodeQuoteDepth: Int?
        var indentedCodeListIndent: Int?
    }

    private struct MarkdownFenceState {
        let marker: Character
        let count: Int
        let quoteDepth: Int
        let listContentIndent: Int?
    }

    private struct MarkdownHTMLBlockState {
        enum Terminator {
            case marker(String, caseInsensitive: Bool)
            case blank
        }

        let terminator: Terminator
        let quoteDepth: Int
        let listContentIndent: Int?

        func ends(in line: String) -> Bool {
            switch terminator {
            case .marker(let marker, let caseInsensitive):
                return caseInsensitive
                    ? line.range(of: marker, options: .caseInsensitive) != nil
                    : line.contains(marker)
            case .blank:
                return line.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }

    private struct MarkdownLineContext {
        let fenceCandidate: String
        let isIndentedCode: Bool
        let isBlank: Bool
        let allowsParagraphContinuation: Bool
        let startsNewInlineBlock: Bool
    }

    /// Bestimmt eingerückte GFM-Codeblöcke relativ zu ihren Containern. Vier
    /// Leerzeichen sind am Dokumentrand Code, innerhalb eines Listeneintrags
    /// aber erst vier Spalten hinter dessen Inhaltseinzug. Blockquote-Marker
    /// werden vorher entfernt; dadurch gelten dieselben Regeln auch für `>` und
    /// verschachtelte Listen in Zitaten.
    private static func lineContext(
        _ line: String,
        containers: inout MarkdownContainerState
    ) -> MarkdownLineContext {
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
            return MarkdownLineContext(
                fenceCandidate: "",
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
                fenceCandidate: String(content[index(after: baseIndent, in: content)...]),
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
            return MarkdownLineContext(
                fenceCandidate: fenceCandidate,
                isIndentedCode: false,
                isBlank: false,
                allowsParagraphContinuation: false,
                startsNewInlineBlock: true
            )
        }

        if relativeIndent <= 3, isThematicBreak(fenceCandidate) {
            containers.indentedCodeQuoteDepth = nil
            containers.indentedCodeListIndent = nil
            return MarkdownLineContext(
                fenceCandidate: fenceCandidate,
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
                return MarkdownLineContext(
                    fenceCandidate: fenceCandidate,
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
        return MarkdownLineContext(
            fenceCandidate: fenceCandidate,
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
        containers: inout MarkdownContainerState
    ) -> MarkdownLineContext {
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
                return MarkdownLineContext(
                    fenceCandidate: fallbackCandidate,
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
                    fenceCandidate: String(content[padding.end...]),
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
            return MarkdownLineContext(
                fenceCandidate: hasContent ? String(content[padding.end...]) : "",
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
        fenceCandidate: String,
        forced: Bool,
        containerChangeStartsBlock: Bool,
        containers: inout MarkdownContainerState
    ) -> MarkdownLineContext {
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
        return MarkdownLineContext(
            fenceCandidate: fenceCandidate,
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

    private static func leadingIndentation(
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

    private static func rewriteInline(
        _ line: String,
        in markdown: String,
        sourceLineStart: String.Index,
        inlineBlockEnd: String.Index,
        backtickIndex: BacktickRunIndex,
        from oldPath: String,
        to newPath: String,
        inlineCodeTicks: inout Int?,
        bracketDepth: inout Int
    ) -> String {
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let closingTickCount = inlineCodeTicks {
                // Backslashes haben in einem Code-Span keine Escape-Funktion.
                // Nur ein vollständiger Backtick-Run gleicher Länge beendet
                // ihn; dadurch kann `\`` das erste Closing-Zeichen nicht mehr
                // vor dem Scanner verstecken.
                if character == "`" {
                    let runEnd = line[index...].firstIndex(where: { $0 != "`" })
                        ?? line.endIndex
                    let count = line.distance(from: index, to: runEnd)
                    result += line[index..<runEnd]
                    if count == closingTickCount {
                        inlineCodeTicks = nil
                    }
                    index = runEnd
                } else {
                    result.append(character)
                    index = line.index(after: index)
                }
                continue
            }
            if character == "\\" {
                result.append(character)
                index = line.index(after: index)
                if index < line.endIndex {
                    result.append(line[index])
                    index = line.index(after: index)
                }
                continue
            }
            if character == "`" {
                let runEnd = line[index...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
                let count = line.distance(from: index, to: runEnd)
                result += line[index..<runEnd]
                // Ein Backtick-Run ohne gleich langen Abschluss ist laut GFM
                // nur Literaltext. Dann bleibt der Inline-Scanner aktiv und
                // kann echte Links hinter diesem Run weiter umschreiben.
                let absoluteRunEnd = markdown.index(
                    sourceLineStart,
                    offsetBy: line.distance(from: line.startIndex, to: runEnd)
                )
                if backtickIndex.hasRun(
                    ofLength: count,
                    after: absoluteRunEnd,
                    before: inlineBlockEnd
                ) {
                    inlineCodeTicks = count
                }
                index = runEnd
                continue
            }
            if character == "[" {
                bracketDepth += 1
            } else if character == "]", bracketDepth > 0 {
                bracketDepth -= 1
                let openingParenthesis = line.index(after: index)
                if openingParenthesis < line.endIndex,
                   line[openingParenthesis] == "(",
                   let replacement = rewrittenTarget(
                    in: line,
                    after: openingParenthesis,
                    from: oldPath,
                    to: newPath
                   ) {
                    result += line[index..<replacement.end]
                    result += replacement.text
                    result += line[replacement.originalPathEnd..<replacement.resumeAt]
                    index = replacement.resumeAt
                    continue
                }
            }
            result.append(character)
            index = line.index(after: index)
        }
        return result
    }

    /// Kandidaten und Ersetzung teilen die Zielgrenzen. Code-/HTML-Zustände
    /// prüft anschließend `replacing`; hier werden noch keine Links verändert.
    static func resourceCandidates(in markdown: String, maximum: Int) throws -> Set<String> {
        var targets = Set<String>()
        let starts = try NSRegularExpression(pattern: #"\]\(|(?m)^\s{0,3}\[[^\]\n]+\]:[ \t]*"#)
        var exceeded = false
        starts.enumerateMatches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) { match, _, stop in
            guard let match, let range = Range(match.range, in: markdown),
                  let target = destination(in: markdown, from: range.upperBound) else { return }
            targets.insert(String(markdown[target.range]))
            if targets.count > maximum { exceeded = true; stop.pointee = true }
        }
        if exceeded { throw ImportFailure("notebook cell exceeds \(maximum) Markdown resource targets") }
        return targets
    }

    private static func destination(
        in text: String, from start: String.Index
    ) -> (range: Range<String.Index>, usesAngles: Bool)? {
        var index = start
        while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
        let angles = index < text.endIndex && text[index] == "<"
        if angles { index = text.index(after: index) }
        let pathStart = index
        var depth = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" || character == "\r" { break }
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next].isASCII, text[next].isPunctuation || text[next].isSymbol {
                    index = text.index(after: next)
                    continue
                }
            }
            if angles {
                if character == ">" { return (pathStart..<index, true) }
                if character == "<" { return nil }
            } else {
                if character == "(" { depth += 1 }
                if character == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                if character.isWhitespace { break }
            }
            index = text.index(after: index)
        }
        guard !angles, depth == 0, index > pathStart else { return nil }
        return (pathStart..<index, false)
    }

    private static func rewrittenTarget(
        in line: String,
        after openingParenthesis: String.Index,
        from oldPath: String,
        to newPath: String
    ) -> (
        end: String.Index,
        text: String,
        originalPathEnd: String.Index,
        resumeAt: String.Index
    )? {
        guard let destination = destination(in: line, from: line.index(after: openingParenthesis)),
              String(line[destination.range]) == oldPath else { return nil }
        let pathStart = destination.range.lowerBound
        let pathEnd = destination.range.upperBound
        let usesAngles = destination.usesAngles
        guard let linkEnd = inlineLinkEnd(
            in: line,
            afterPath: pathEnd,
            usesAngles: usesAngles
        ) else { return nil }
        return (pathStart, newPath, pathEnd, linkEnd)
    }

    /// Konsumiert den optionalen Linktitel als Teil derselben Syntaxeinheit.
    /// Backticks in `"Titel`"` sind kein Inline-Code und dürfen den Scanner für
    /// nachfolgende echte Links nicht in einen falschen Zustand versetzen.
    private static func inlineLinkEnd(
        in line: String,
        afterPath pathEnd: String.Index,
        usesAngles: Bool
    ) -> String.Index? {
        var index = pathEnd
        if usesAngles {
            guard index < line.endIndex, line[index] == ">" else { return nil }
            index = line.index(after: index)
        }
        if index < line.endIndex, line[index] == ")" {
            return line.index(after: index)
        }

        var hadWhitespace = false
        while index < line.endIndex, line[index].isWhitespace {
            hadWhitespace = true
            index = line.index(after: index)
        }
        guard hadWhitespace, index < line.endIndex else { return nil }

        let opener = line[index]
        let closer: Character
        switch opener {
        case "\"": closer = "\""
        case "'": closer = "'"
        case "(": closer = ")"
        default: return nil
        }
        index = line.index(after: index)
        var escaped = false
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == closer {
                index = line.index(after: index)
                while index < line.endIndex, line[index].isWhitespace {
                    index = line.index(after: index)
                }
                guard index < line.endIndex, line[index] == ")" else { return nil }
                return line.index(after: index)
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Entfernt nur die Container-Präfixe, in denen das Fence geöffnet wurde.
    /// Fehlt ein benötigter Blockquote-Marker oder Listeneinzug, gehört die
    /// aktuelle Zeile bereits zum äußeren Container und beendet das Fence.
    private static func fenceContent(
        in line: String,
        fence: MarkdownFenceState
    ) -> String? {
        var contentStart = line.startIndex
        for _ in 0..<fence.quoteDepth {
            var marker = contentStart
            var spaces = 0
            while marker < line.endIndex, line[marker] == " ", spaces < 3 {
                spaces += 1
                marker = line.index(after: marker)
            }
            guard marker < line.endIndex, line[marker] == ">" else { return nil }
            marker = line.index(after: marker)
            if marker < line.endIndex,
               line[marker] == " " || line[marker] == "\t" {
                marker = line.index(after: marker)
            }
            contentStart = marker
        }

        let content = line[contentStart...]
        if content.allSatisfy(\.isWhitespace) {
            return ""
        }
        guard let requiredIndent = fence.listContentIndent else {
            return String(content)
        }
        let indentation = leadingIndentation(in: content)
        guard indentation.columns >= requiredIndent else { return nil }
        return String(content[index(after: requiredIndent, in: content)...])
    }

    /// Entfernt ausschließlich die Container-Präfixe des öffnenden HTML-
    /// Blocks. Der verbleibende Literalinhalt läuft absichtlich NICHT durch
    /// `lineContext`: Ein `>` oder Listenmarker darin ist HTML-Text und kein
    /// Wechsel des Markdown-Containers.
    private static func htmlContent(
        in line: String,
        block: MarkdownHTMLBlockState
    ) -> String? {
        var contentStart = line.startIndex
        for _ in 0..<block.quoteDepth {
            var marker = contentStart
            var spaces = 0
            while marker < line.endIndex, line[marker] == " ", spaces < 3 {
                spaces += 1
                marker = line.index(after: marker)
            }
            guard marker < line.endIndex, line[marker] == ">" else { return nil }
            marker = line.index(after: marker)
            if marker < line.endIndex,
               line[marker] == " " || line[marker] == "\t" {
                marker = line.index(after: marker)
            }
            contentStart = marker
        }

        let content = line[contentStart...]
        if content.allSatisfy(\.isWhitespace) { return "" }
        guard let requiredIndent = block.listContentIndent else {
            return String(content)
        }
        let indentation = leadingIndentation(in: content)
        guard indentation.columns >= requiredIndent else { return nil }
        return String(content[index(after: requiredIndent, in: content)...])
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
    ) -> (terminator: MarkdownHTMLBlockState.Terminator, canInterruptParagraph: Bool)? {
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
        fence: (marker: Character, count: Int)
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
