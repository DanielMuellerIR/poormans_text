import Foundation

/// Schreibt Asset-Ziele in echten Markdown-Links um und lässt wörtlichen Code
/// unangetastet. Ein bloßes Suchen nach `](ziel)` kann denselben Text in einem
/// Code-Span, einem Codeblock oder hinter einem Escape treffen.
enum MarkdownLinkTargetRewriter {
    static func replacing(in markdown: String, from oldPath: String, to newPath: String) -> String {
        var result = ""
        var fencedCode: MarkdownFenceState?
        var inlineCodeTicks: Int?
        var bracketDepth = 0
        var containers = MarkdownContainerState()

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
            let context = lineContext(text, containers: &containers)
            if context.isBlank || context.startsNewInlineBlock
                || openingFence(context.fenceCandidate) != nil {
                // Inline-Konstrukte enden an der Markdown-Blockgrenze. Ein
                // Backtick in einem späteren Block darf daher weder einen
                // Code-Span schließen noch einen offenen Linktext fortsetzen.
                inlineCodeTicks = nil
                bracketDepth = 0
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
                result += rewriteInline(
                    text,
                    followingMarkdown: context.allowsParagraphContinuation
                        && text.contains("`")
                        ? followingInlineBlock(
                            after: line,
                            in: markdown,
                            containers: lookaheadContainers
                        )
                        : markdown[line.endIndex..<line.endIndex],
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
    private static func followingInlineBlock(
        after line: Substring,
        in markdown: String,
        containers: MarkdownContainerState
    ) -> Substring {
        let following = markdown[line.endIndex...]
        guard !following.isEmpty else { return following }

        var lookaheadContainers = containers
        var lineStart = following.startIndex
        if following[lineStart] == "\n" {
            lineStart = following.index(after: lineStart)
        }
        while lineStart < following.endIndex {
            let lineEnd = following[lineStart...].firstIndex(of: "\n")
                ?? following.endIndex
            let candidate = following[lineStart..<lineEnd]
            let context = lineContext(String(candidate), containers: &lookaheadContainers)
            if context.isBlank || context.startsNewInlineBlock
                || openingFence(context.fenceCandidate) != nil {
                return following[..<lineStart]
            }
            lookaheadContainers.canStartIndentedCode = context.isBlank
                || !context.allowsParagraphContinuation
            guard lineEnd < following.endIndex else { break }
            lineStart = following.index(after: lineEnd)
        }
        return following
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
            let padding = followingWhitespace(
                in: content,
                from: marker.end,
                initialColumn: indentation.columns + marker.width
            )
            let hasContent = padding.end < content.endIndex
            guard !hasContent || padding.columns > 0 else {
                containers.indentedCodeQuoteDepth = nil
                containers.indentedCodeListIndent = nil
                return MarkdownLineContext(
                    fenceCandidate: String(content[index(after: baseIndent, in: content)...]),
                    isIndentedCode: false,
                    isBlank: false,
                    allowsParagraphContinuation: true,
                    startsNewInlineBlock: false
                )
            }
            let effectivePadding = hasContent && padding.columns > 4 ? 1 : max(1, padding.columns)
            containers.listContentIndents.append(
                indentation.columns + marker.width + effectivePadding
            )
            let isIndentedCandidate = hasContent && padding.columns > 4
            if isIndentedCandidate {
                return indentedCodeContext(
                    fenceCandidate: String(content[padding.end...]),
                    forced: true,
                    containerChangeStartsBlock: containerChanged,
                    containers: &containers
                )
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
    ) -> (end: String.Index, width: Int)? {
        guard start < text.endIndex else { return nil }
        if "-+*".contains(text[start]) {
            return (text.index(after: start), 1)
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
        return (text.index(after: end), digits + 1)
    }

    private static func rewriteInline(
        _ line: String,
        followingMarkdown: Substring,
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
                if containsBacktickRun(ofLength: count, in: line[runEnd...])
                    || containsBacktickRun(ofLength: count, in: followingMarkdown) {
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
                    index = replacement.resumeAt
                    continue
                }
            }
            result.append(character)
            index = line.index(after: index)
        }
        return result
    }

    private static func containsBacktickRun(
        ofLength expectedCount: Int,
        in text: Substring
    ) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }
            let runEnd = text[index...].firstIndex(where: { $0 != "`" })
                ?? text.endIndex
            if text.distance(from: index, to: runEnd) == expectedCount {
                return true
            }
            index = runEnd
        }
        return false
    }

    private static func rewrittenTarget(
        in line: String,
        after openingParenthesis: String.Index,
        from oldPath: String,
        to newPath: String
    ) -> (end: String.Index, text: String, resumeAt: String.Index)? {
        let targetStart = line.index(after: openingParenthesis)
        let usesAngles = targetStart < line.endIndex && line[targetStart] == "<"
        let pathStart = usesAngles ? line.index(after: targetStart) : targetStart
        guard line[pathStart...].hasPrefix(oldPath) else { return nil }
        let pathEnd = line.index(pathStart, offsetBy: oldPath.count)
        if usesAngles {
            guard pathEnd < line.endIndex, line[pathEnd] == ">" else { return nil }
        } else {
            guard pathEnd < line.endIndex,
                  line[pathEnd] == ")" || line[pathEnd].isWhitespace else {
                return nil
            }
        }
        return (pathStart, newPath, pathEnd)
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
