import Foundation

/// Schreibt Asset-Ziele in echten Markdown-Links um und lässt wörtlichen Code
/// unangetastet. Ein bloßes Suchen nach `](ziel)` kann denselben Text in einem
/// Code-Span, einem Codeblock oder hinter einem Escape treffen.
enum MarkdownLinkTargetRewriter {
    /// Die Normalisierung muss Code in denselben Listen- und Zitatcontainern
    /// schützen wie die Linkersetzung. Ein Fence endet auch am Containerende.
    static func codeLines(in lines: [String]) -> [Bool] {
        var containers = MarkdownContainerState()
        var fencedCode: MarkdownFenceState?
        return lines.map { line in
            if let fence = fencedCode, let candidate = fenceContent(in: line, fence: fence) {
                if isClosingFence(candidate, fence: (fence.marker, fence.count)) { fencedCode = nil }
                containers.canStartIndentedCode = true
                return true
            }
            fencedCode = nil
            let context = lineContext(line, containers: &containers)
            if context.isIndentedCode {
                containers.canStartIndentedCode = true
                return true
            }
            if let fence = openingFence(context.fenceCandidate) {
                fencedCode = MarkdownFenceState(marker: fence.marker, count: fence.count,
                    prefixes: context.prefixes)
                containers.canStartIndentedCode = true
                return true
            }
            containers.canStartIndentedCode = context.isBlank || !context.allowsParagraphContinuation
            return false
        }
    }

    static func replacing(in markdown: String, from oldPath: String, to newPath: String) -> String {
        replacing(in: markdown, mapping: [oldPath: newPath])
    }

    /// Alle Ziele in EINEM Durchlauf ersetzen.
    ///
    /// Je Aufruf wird das ganze Markdown einmal zerlegt. Der Notebook-Import
    /// rief das vorher je Anhang einmal auf: Ein 2,6 MB großes Notebook mit
    /// 20 000 Anhängen lief dadurch über zehn Minuten und ließ sich nicht
    /// abbrechen (Review-Fund 2026-09-10).
    static func replacing(in markdown: String, mapping: [String: String]) -> String {
        guard !mapping.isEmpty else { return markdown }
        return try! rewrite(markdown, mapping: mapping)
    }

    /// Wie `replacing`, prüft aber während des Durchlaufs regelmäßig einen
    /// möglichen Abbruch. Notebook-Zellen können mehrere MiB groß sein.
    static func replacing(
        in markdown: String,
        mapping: [String: String],
        checking check: @escaping () throws -> Void
    ) throws -> String {
        guard !mapping.isEmpty else {
            try check()
            return markdown
        }
        return try rewrite(markdown, mapping: mapping, check: check)
    }

    private static func rewrite(
        _ markdown: String,
        mapping: [String: String],
        targetObserver: ((String) -> Void)? = nil,
        check: (() throws -> Void)? = nil
    ) throws -> String {
        var result = ""
        var fencedCode: MarkdownFenceState?
        var htmlBlock: MarkdownHTMLBlockState?
        var containers = MarkdownContainerState()

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var consumedLine: Int?
        for (lineNumber, line) in lines.enumerated() {
            if let consumedLine, lineNumber <= consumedLine { continue }
            try check?()
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
                    prefixes: context.prefixes
                )
                if !state.ends(in: context.fenceCandidate) {
                    htmlBlock = state
                }
                containers.canStartIndentedCode = true
                if line.endIndex != markdown[...].endIndex {
                    result += "\n"
                }
                continue
            }
            if !context.isIndentedCode,
               !paragraphWasOpen || context.startsNewInlineBlock || markdownContainerChanged {
                var definitionText = context.fenceCandidate
                var definitionLines = [text]
                var contentLines = [context.fenceCandidate]
                var continuationContainers = containers
                var definition = try referenceDefinition(in: definitionText)
                while definition?.needsContinuation == true,
                      lineNumber + definitionLines.count < lines.count {
                    try check?()
                    let nextText = String(lines[lineNumber + definitionLines.count])
                    let nextContext = lineContext(nextText, containers: &continuationContainers)
                    guard !nextContext.isBlank,
                          (!nextContext.startsNewInlineBlock || nextContext.isIndentedCode),
                          openingFence(nextContext.fenceCandidate) == nil,
                          openingHTMLBlock(nextContext.fenceCandidate)?.canInterruptParagraph != true,
                          continuationContainers.quoteDepth == containers.quoteDepth,
                          continuationContainers.listContentIndents == containers.listContentIndents else { break }
                    definitionLines.append(nextText)
                    contentLines.append(nextContext.fenceCandidate)
                    definitionText += "\n" + nextContext.fenceCandidate
                    if let delimiter = definition?.delimiter {
                        // Lange Titel nur am möglichen Ende erneut parsen; sonst
                        // würde jede Fortsetzungszeile den gesamten Titel lesen.
                        var escaped = false
                        let hasBoundary = nextContext.fenceCandidate.contains { character in
                            if escaped { escaped = false; return false }
                            if character == "\\" { escaped = true; return false }
                            return character == delimiter || (delimiter == "]" && character == "[")
                                || (delimiter == ")" && character == "(")
                        }
                        if !hasBoundary {
                            if delimiter == "]", definitionText.count > 1_003 { break }
                            continue
                        }
                    }
                    definition = try referenceDefinition(in: definitionText)
                }
                // Ein Titel auf Folgezeilen gehört zur Definition. Seine Backticks
                // dürfen deshalb keinen Codezustand im folgenden Absatz öffnen.
                if definition?.target != nil, lineNumber + definitionLines.count < lines.count {
                    var titleContainers = continuationContainers
                    var titleLines = [String]()
                    var titleContents = [String]()
                    var probe = definitionText
                    var titleDelimiter: Character?
                    while lineNumber + definitionLines.count + titleLines.count < lines.count {
                        try check?()
                        let next = String(lines[lineNumber + definitionLines.count + titleLines.count])
                        let context = lineContext(next, containers: &titleContainers)
                        guard !context.isBlank, (!context.startsNewInlineBlock || context.isIndentedCode),
                              openingFence(context.fenceCandidate) == nil,
                              openingHTMLBlock(context.fenceCandidate)?.canInterruptParagraph != true,
                              titleContainers.quoteDepth == containers.quoteDepth,
                              titleContainers.listContentIndents == containers.listContentIndents else { break }
                        if titleLines.isEmpty {
                            let title = context.fenceCandidate.trimmingCharacters(in: .whitespaces)
                            guard let first = title.first, ["\"", "'", "("].contains(String(first)) else { break }
                            titleDelimiter = first == "(" ? ")" : first
                        }
                        titleLines.append(next)
                        titleContents.append(context.fenceCandidate)
                        probe += "\n" + context.fenceCandidate
                        // Erst mögliche Abschlusszeilen prüfen, damit lange Titel linear gelesen werden.
                        if titleLines.count > 1, let delimiter = titleDelimiter,
                           !context.fenceCandidate.contains(delimiter),
                           !(delimiter == ")" && context.fenceCandidate.contains("(")) { continue }
                        guard let parsed = try referenceDefinition(in: probe) else { break }
                        if parsed.target != nil {
                            definitionText = probe
                            definition = parsed
                            definitionLines += titleLines
                            contentLines += titleContents
                            continuationContainers = titleContainers
                            break
                        }
                        if !parsed.needsContinuation { break }
                    }
                }
                if let target = definition?.target {
                    let original = String(definitionText[target])
                    let decoded = decodedTarget(original)
                    targetObserver?(decoded)
                    let mapped = mappedTarget(original, mapping: mapping)
                    let offset = definitionText.distance(from: definitionText.startIndex, to: target.lowerBound)
                    var lineOffset = 0
                    for index in contentLines.indices {
                        let content = contentLines[index]
                        if offset >= lineOffset, offset < lineOffset + content.count,
                           let contentRange = definitionLines[index].range(of: content, options: .backwards) {
                            let start = definitionLines[index].index(contentRange.lowerBound, offsetBy: offset - lineOffset)
                            let end = definitionLines[index].index(start, offsetBy: original.count)
                            definitionLines[index].replaceSubrange(start..<end, with: mapped ?? original)
                            break
                        }
                        lineOffset += content.count + 1
                    }
                    result += definitionLines.joined(separator: "\n")
                    consumedLine = lineNumber + definitionLines.count - 1
                    containers = continuationContainers
                    containers.canStartIndentedCode = true
                        if lines[consumedLine!].endIndex != markdown.endIndex { result += "\n" }
                    continue
                }
            }
            if context.isIndentedCode {
                result += text
                containers.canStartIndentedCode = true
            } else if let fence = openingFence(context.fenceCandidate) {
                result += text
                fencedCode = MarkdownFenceState(
                    marker: fence.marker,
                    count: fence.count,
                    prefixes: context.prefixes
                )
                containers.canStartIndentedCode = true
            } else {
                let rewritten = try rewriteInlineBlock(
                    lines, startingAt: lineNumber, in: markdown,
                    firstContext: context, containers: containers,
                    mapping: mapping, targetObserver: targetObserver, check: check
                )
                result += rewritten.text
                consumedLine = rewritten.lastLine
                containers = rewritten.containers
                if lines[rewritten.lastLine].endIndex != markdown.endIndex { result += "\n" }
                continue
            }
            if line.endIndex != markdown[...].endIndex {
                result += "\n"
            }
        }
        return result
    }

    /// Ein Inlineblock wird einmal ohne Container-Präfixe gescannt. Nur die
    /// Zielbereiche werden anschließend im Original ersetzt; Zitatmarker,
    /// Einzüge, Umbrüche und Titel bleiben dadurch bytegleich erhalten.
    private static func rewriteInlineBlock(
        _ lines: [Substring], startingAt firstLine: Int, in markdown: String,
        firstContext: MarkdownLineContext, containers initialContainers: MarkdownContainerState,
        mapping: [String: String], targetObserver: ((String) -> Void)?, check: (() throws -> Void)?
    ) throws -> (text: String, lastLine: Int, containers: MarkdownContainerState) {
        var contents = [firstContext.fenceCandidate]
        var originalStarts = [lines[firstLine].index(lines[firstLine].endIndex, offsetBy: -firstContext.fenceCandidate.count)]
        var containers = initialContainers
        containers.canStartIndentedCode = firstContext.isBlank || !firstContext.allowsParagraphContinuation
        var lastLine = firstLine
        if firstContext.allowsParagraphContinuation {
            while lastLine + 1 < lines.count {
                try check?()
                let next = lines[lastLine + 1]
                var nextContainers = containers
                let context = lineContext(String(next), containers: &nextContainers)
                let changed = containers.quoteDepth != nextContainers.quoteDepth
                    || containers.listContentIndents != nextContainers.listContentIndents
                let html = openingHTMLBlock(context.fenceCandidate)
                let interruptsWithHTML = !context.isIndentedCode
                    && (html?.canInterruptParagraph == true || (html != nil && changed))
                if context.isBlank || context.startsNewInlineBlock
                    || openingFence(context.fenceCandidate) != nil || interruptsWithHTML { break }
                contents.append(context.fenceCandidate)
                originalStarts.append(next.index(next.endIndex, offsetBy: -context.fenceCandidate.count))
                nextContainers.canStartIndentedCode = context.isBlank || !context.allowsParagraphContinuation
                containers = nextContainers
                lastLine += 1
                if !context.allowsParagraphContinuation { break }
            }
        }
        let logical = contents.joined(separator: "\n")
        let segments = logical.split(separator: "\n", omittingEmptySubsequences: false)
        var segment = 0
        var logicalCursor = logical.startIndex
        var originalCursor = originalStarts[0]
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        var ticks: Int?
        var brackets = 0
        try rewriteInline(
            logical, inlineBlockEnd: logical.endIndex,
            backtickIndex: try BacktickRunIndex(logical, check: check), mapping: mapping, targetObserver: targetObserver,
            replacementObserver: { range, replacement in
                while segment + 1 < segments.count, range.lowerBound >= segments[segment].endIndex {
                    segment += 1
                    logicalCursor = segments[segment].startIndex
                    originalCursor = originalStarts[segment]
                }
                guard range.lowerBound >= logicalCursor, range.upperBound <= segments[segment].endIndex else { return }
                let start = markdown.index(originalCursor, offsetBy: logical.distance(from: logicalCursor, to: range.lowerBound))
                let end = markdown.index(start, offsetBy: logical.distance(from: range.lowerBound, to: range.upperBound))
                edits.append((start..<end, replacement))
                logicalCursor = range.upperBound
                originalCursor = end
            }, check: check, inlineCodeTicks: &ticks, bracketDepth: &brackets
        )
        var output = ""
        var cursor = lines[firstLine].startIndex
        for edit in edits {
            try check?()
            output += markdown[cursor..<edit.range.lowerBound]
            output += edit.replacement
            cursor = edit.range.upperBound
        }
        output += markdown[cursor..<lines[lastLine].endIndex]
        return (output, lastLine, containers)
    }

    /// Indexiert jeden Backtick-Lauf einmal. Eine binäre Suche beantwortet
    /// danach für jeden möglichen Öffner, ob vor der Absatzgrenze ein gleich
    /// langer Abschluss folgt; kein Absatzrest wird pro Zeile erneut gescannt.
    private struct BacktickRunIndex {
        private let startsByLength: [Int: [String.Index]]

        init(_ markdown: String, check: (() throws -> Void)?) throws {
            var starts = [Int: [String.Index]]()
            var index = markdown.startIndex
            var scanned = 0
            while index < markdown.endIndex {
                if scanned % 1_024 == 0 { try check?() }; scanned += 1
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
        var prefixes: [ContainerPrefix] = []
    }

    private struct MarkdownFenceState {
        let marker: Character
        let count: Int
        let prefixes: [ContainerPrefix]
    }

    private enum ContainerPrefix {
        case quote
        case indent(Int)
    }

    private struct MarkdownHTMLBlockState {
        enum Terminator {
            case marker(String, caseInsensitive: Bool)
            case blank
        }

        let terminator: Terminator
        let prefixes: [ContainerPrefix]

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

    private struct MarkdownLineContext {
        let fenceCandidate: String
        let isIndentedCode: Bool
        let isBlank: Bool
        let allowsParagraphContinuation: Bool
        let startsNewInlineBlock: Bool
        var prefixes: [ContainerPrefix] = []
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
                var nested = MarkdownContainerState()
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
            let candidate = context.fenceCandidate
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
                context = MarkdownLineContext(fenceCandidate: inner,
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

    private struct ParenthesisIndex {
        var matchingClose: [String.Index: String.Index] = [:]

        init(_ text: String, check: (() throws -> Void)?) throws {
            var stack: [String.Index] = []
            var cursor = text.startIndex
            var scanned = 0
            while cursor < text.endIndex {
                if scanned % 1_024 == 0 { try check?() }; scanned += 1
                let character = text[cursor]
                if character == "\\" {
                    let next = text.index(after: cursor)
                    if next < text.endIndex, text[next].isASCII, text[next].isPunctuation || text[next].isSymbol {
                        cursor = text.index(after: next)
                        continue
                    }
                }
                if character.isWhitespace { stack.removeAll(keepingCapacity: true) }
                else if character == "(" { stack.append(cursor) }
                else if character == ")", let opening = stack.popLast() { matchingClose[opening] = cursor }
                cursor = text.index(after: cursor)
            }
        }
    }

    private static let inlineHTML = try! NSRegularExpression(pattern:
        #"<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[[\s\S]*?\]\]>|<![A-Z][^>]*>|</[A-Za-z][A-Za-z0-9-]*\s*>|<[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:[^\s\"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*/?>"#)

    private static func rewriteInline(
        _ line: String,
        inlineBlockEnd: String.Index,
        backtickIndex: BacktickRunIndex,
        mapping: [String: String],
        targetObserver: ((String) -> Void)?,
        replacementObserver: ((Range<String.Index>, String) -> Void)?,
        check: (() throws -> Void)?,
        inlineCodeTicks: inout Int?,
        bracketDepth: inout Int
    ) throws {
        let parentheses = try ParenthesisIndex(line, check: check)
        let lastCommentClose = line.range(of: "-->", options: .backwards)?.lowerBound
        let lastProcessingClose = line.range(of: "?>", options: .backwards)?.lowerBound
        let lastCDATAClose = line.range(of: "]]>", options: .backwards)?.lowerBound
        try check?()
        var index = line.startIndex
        var scanned = 0
        while index < line.endIndex {
            if scanned % 1_024 == 0 { try check?() }; scanned += 1
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
                    if count == closingTickCount {
                        inlineCodeTicks = nil
                    }
                    index = runEnd
                } else {
                    index = line.index(after: index)
                }
                continue
            }
            if character == "\\" {
                index = line.index(after: index)
                if index < line.endIndex {
                    index = line.index(after: index)
                }
                continue
            }
            if character == "`" {
                let runEnd = line[index...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
                let count = line.distance(from: index, to: runEnd)
                // Ein Backtick-Run ohne gleich langen Abschluss ist laut GFM
                // nur Literaltext. Dann bleibt der Inline-Scanner aktiv und
                // kann echte Links hinter diesem Run weiter umschreiben.
                if backtickIndex.hasRun(
                    ofLength: count,
                    after: runEnd,
                    before: inlineBlockEnd
                ) {
                    inlineCodeTicks = count
                }
                index = runEnd
                continue
            }
            if character == "<" {
                let rest = line[index...]
                let hasTerminator: Bool
                if rest.hasPrefix("<!--") { hasTerminator = lastCommentClose.map { $0 > index } ?? false }
                else if rest.hasPrefix("<?") { hasTerminator = lastProcessingClose.map { $0 > index } ?? false }
                else if rest.hasPrefix("<![CDATA[") { hasTerminator = lastCDATAClose.map { $0 > index } ?? false }
                else { hasTerminator = true }
                if hasTerminator, let match = inlineHTML.firstMatch(in: line, options: .anchored,
                    range: NSRange(index..<line.endIndex, in: line)), let range = Range(match.range, in: line) {
                    index = range.upperBound
                    continue
                }
            }
            if character == "[" {
                bracketDepth += 1
            } else if character == "]", bracketDepth > 0 {
                bracketDepth -= 1
                let openingParenthesis = line.index(after: index)
                if openingParenthesis < line.endIndex,
                   line[openingParenthesis] == "(",
                   let replacement = try rewrittenTarget(
                    in: line,
                    after: openingParenthesis,
                    mapping: mapping,
                    targetObserver: targetObserver, parentheses: parentheses, check: check
                   ) {
                    if replacement.text != line[replacement.end..<replacement.originalPathEnd] {
                        replacementObserver?(replacement.end..<replacement.originalPathEnd, replacement.text)
                    }
                    index = replacement.resumeAt
                    continue
                }
            }
            index = line.index(after: index)
        }
    }

    /// Sammelt nur Ziele echter Markdown-Links. Derselbe Scanner wie beim
    /// Umschreiben überspringt Code-Spans, Codeblöcke und HTML-Blöcke; dadurch
    /// können dortige Beispiele das Zielbudget nicht mehr ausschöpfen.
    static func resourceCandidates(
        in markdown: String,
        maximum: Int,
        checking check: @escaping () throws -> Void
    ) throws -> Set<String> {
        var targets = Set<String>()
        var exceeded = false
        _ = try rewrite(
            markdown,
            mapping: [:],
            targetObserver: { target in
                guard !exceeded else { return }
                targets.insert(target)
                exceeded = targets.count > maximum
            },
            check: check
        )
        if exceeded { throw ImportFailure("notebook cell exceeds \(maximum) Markdown resource targets") }
        return targets
    }

    private static func referenceDefinition(in text: String) throws -> (target: Range<String.Index>?, needsContinuation: Bool, delimiter: Character?)? {
        let indent = leadingIndentation(in: text[...])
        guard indent.columns <= 3, indent.end < text.endIndex, text[indent.end] == "[" else { return nil }
        var cursor = text.index(after: indent.end)
        let labelStart = cursor
        while cursor < text.endIndex, text[cursor] != "]" {
            if text[cursor] == "[" { return nil }
            if text[cursor] == "\\" { cursor = text.index(after: cursor); if cursor == text.endIndex { return nil } }
            cursor = text.index(after: cursor)
        }
        guard text.distance(from: labelStart, to: cursor) <= 999 else { return nil }
        if cursor == text.endIndex { return (nil, true, "]") }
        guard !text[labelStart..<cursor].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        cursor = text.index(after: cursor)
        guard cursor < text.endIndex, text[cursor] == ":" else { return nil }
        cursor = text.index(after: cursor)
        if let target = try referenceDestination(in: text, from: cursor) { return (target, false, nil) }
        if text[cursor...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (nil, true, nil) }
        guard let target = try destination(in: text, from: cursor) else { return nil }
        var tailStart = target.range.upperBound
        if target.usesAngles { tailStart = text.index(after: tailStart) }
        let tail = text[tailStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opener = tail.first, ["\"", "'", "("].contains(String(opener)) else { return nil }
        let closer: Character = opener == "(" ? ")" : opener
        var escaped = false
        for character in tail.dropFirst() {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == closer || (opener == "(" && character == "(") { return nil }
        }
        return (nil, true, closer)
    }

    private static func referenceDestination(in text: String, from start: String.Index) throws -> Range<String.Index>? {
        guard let target = try destination(in: text, from: start) else { return nil }
        var end = target.range.upperBound
        if target.usesAngles { end = text.index(after: end) }
        if end == text.endIndex { return target.range }
        guard text[end].isWhitespace else { return nil }
        let tail = text[end...].trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty { return target.range }
        guard let opener = tail.first, let closer = ["\"": "\"", "'": "'", "(": ")"][String(opener)],
              tail.count >= 2, tail.last.map(String.init) == closer else { return nil }
        let body = tail.dropFirst().dropLast()
        var escaped = false
        for character in body {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if String(character) == closer || (opener == "(" && character == "(") { return nil }
        }
        return escaped ? nil : target.range
    }

    private static func destination(
        in text: String, from start: String.Index, parentheses: ParenthesisIndex? = nil, check: (() throws -> Void)? = nil
    ) throws -> (range: Range<String.Index>, usesAngles: Bool)? {
        var index = start
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        let angles = index < text.endIndex && text[index] == "<"
        if angles { index = text.index(after: index) }
        let pathStart = index
        var depth = 0
        var scanned = 0
        while index < text.endIndex {
            if scanned % 1_024 == 0 { try check?() }; scanned += 1
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
                if character == "(" {
                    if let parentheses {
                        guard let closing = parentheses.matchingClose[index] else { return nil }
                        index = text.index(after: closing)
                        continue
                    }
                    depth += 1
                }
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
        mapping: [String: String],
        targetObserver: ((String) -> Void)?,
        parentheses: ParenthesisIndex, check: (() throws -> Void)?
    ) throws -> (
        end: String.Index,
        text: String,
        originalPathEnd: String.Index,
        resumeAt: String.Index
    )? {
        guard let destination = try destination(in: line, from: line.index(after: openingParenthesis), parentheses: parentheses, check: check) else {
            return nil
        }
        let target = String(line[destination.range])
        let pathStart = destination.range.lowerBound
        let pathEnd = destination.range.upperBound
        guard let linkEnd = try inlineLinkEnd(in: line, afterPath: pathEnd, usesAngles: destination.usesAngles, check: check) else { return nil }
        targetObserver?(decodedTarget(target))
        let replacement = mappedTarget(target, mapping: mapping) ?? target
        return (pathStart, replacement, pathEnd, linkEnd)
    }

    private static func mappedTarget(_ target: String, mapping: [String: String]) -> String? {
        if let mapped = mapping[target] { return mapped }
        let decoded = decodedTarget(target)
        if let mapped = mapping[decoded] { return mapped.hasPrefix("#") ? mapped : percentEncodedPath(mapped) }
        return decoded.removingPercentEncoding.flatMap { mapping[$0].map(percentEncodedPath) }
    }

    /// Escapes und Zeichenreferenzen gehören zur Markdown-Syntax, nicht zum Dateinamen.
    private static func decodedTarget(_ target: String) -> String {
        var output = ""
        var index = target.startIndex
        while index < target.endIndex {
            let character = target[index]
            let next = target.index(after: index)
            if character == "\\", next < target.endIndex, target[next].isASCII,
               target[next].isPunctuation || target[next].isSymbol {
                output.append(target[next])
                index = target.index(after: next)
                continue
            }
            if character == "&", let end = target[next...].prefix(33).firstIndex(of: ";") {
                let name = String(target[next..<end])
                var value = MarkdownCharacterReferences.named[name]
                if name.hasPrefix("#") {
                    let hex = name.hasPrefix("#x") || name.hasPrefix("#X")
                    let digits = String(name.dropFirst(hex ? 2 : 1))
                    if !digits.isEmpty, digits.count <= (hex ? 6 : 7),
                       digits.allSatisfy({ hex ? $0.isHexDigit : $0.isASCII && $0.isNumber }),
                       let number = UInt32(digits, radix: hex ? 16 : 10) {
                        value = UnicodeScalar(number).flatMap { $0.value == 0 ? nil : String($0) } ?? "\u{FFFD}"
                    }
                }
                if let value {
                    output += value
                    index = target.index(after: end)
                    continue
                }
            }
            output.append(character)
            index = next
        }
        return output
    }

    /// Kodiert jeden Pfadbestandteil einzeln, damit die Trennstriche `/`
    /// erhalten bleiben. Derselbe erlaubte Zeichensatz wie in
    /// `HTMLImageRewriter`, das die Links ursprünglich schreibt.
    static func percentEncodedPath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: allowed)
                    ?? String(component)
            }
            .joined(separator: "/")
    }

    /// Konsumiert den optionalen Linktitel als Teil derselben Syntaxeinheit.
    /// Backticks in `"Titel`"` sind kein Inline-Code und dürfen den Scanner für
    /// nachfolgende echte Links nicht in einen falschen Zustand versetzen.
    private static func inlineLinkEnd(
        in line: String,
        afterPath pathEnd: String.Index,
        usesAngles: Bool, check: (() throws -> Void)?
    ) throws -> String.Index? {
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
        if line[index] == ")" { return line.index(after: index) }

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
        var scanned = 0
        while index < line.endIndex {
            if scanned % 1_024 == 0 { try check?() }; scanned += 1
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
        containerContent(in: line, prefixes: fence.prefixes)
    }

    private static func htmlContent(in line: String, block: MarkdownHTMLBlockState) -> String? {
        containerContent(in: line, prefixes: block.prefixes)
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
