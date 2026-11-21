import Foundation

/// Schreibt Asset-Ziele in echten Markdown-Links um und lässt wörtlichen Code
/// unangetastet. Ein bloßes Suchen nach `](ziel)` kann denselben Text in einem
/// Code-Span, einem Codeblock oder hinter einem Escape treffen.
enum MarkdownLinkTargetRewriter {
    static func replacing(in markdown: String, from oldPath: String, to newPath: String) -> String {
        replacing(in: markdown, mapping: [oldPath: newPath])
    }

    /// Ein Durchlauf für alle Zuordnungen vermeidet wiederholtes Scannen
    /// etwa bei Notebook-Zellen mit vielen Anhängen.
    static func replacing(in markdown: String, mapping: [String: String]) -> String {
        guard !mapping.isEmpty else { return markdown }
        return rewrite(markdown, mapping: mapping, check: {})
    }

    /// Wie `replacing`, prüft aber während des Durchlaufs regelmäßig einen
    /// möglichen Abbruch. Notebook-Zellen können mehrere MiB groß sein.
    static func replacing(
        in markdown: String,
        mapping: [String: String],
        checking check: () throws -> Void,
        observing observer: ((ConversionTextEdit) -> Void)? = nil
    ) rethrows -> String {
        guard !mapping.isEmpty else {
            try check()
            return markdown
        }
        let callback: ((Range<String.Index>, String) -> Void)? = observer.map { observer in
            { range, replacement in
                observer(
                    ConversionTextEdit(
                        offset: markdown.utf8.distance(from: markdown.startIndex, to: range.lowerBound),
                        length: markdown.utf8.distance(from: range.lowerBound, to: range.upperBound),
                        replacementLength: replacement.utf8.count))
            }
        }
        return try rewrite(markdown, mapping: mapping, replacementObserver: callback, check: check)
    }

    private static func rewrite(
        _ markdown: String,
        mapping: [String: String],
        targetObserver: ((String) -> Void)? = nil,
        replacementObserver: ((Range<String.Index>, String) -> Void)? = nil,
        check: () throws -> Void
    ) rethrows -> String {
        var result = ""
        var fencedCode: MarkdownBlockScanner.Fence?
        var htmlBlock: MarkdownBlockScanner.HTMLBlock?
        var containers = MarkdownBlockScanner.Containers()

        let lines = markdown.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r\n" || $0 == "\r"
        }
        var consumedLine: Int?
        for (lineNumber, line) in lines.enumerated() {
            if let consumedLine, lineNumber <= consumedLine { continue }
            try check()
            let text = String(line)
            if let fence = fencedCode,
                let fenceCandidate = fence.content(in: text)
            {
                result += text
                if fence.ends(in: fenceCandidate) {
                    fencedCode = nil
                }
                containers.canStartIndentedCode = true
                result += lineEnding(after: line, in: markdown)
                continue
            }
            // Ein Fence endet mit seinem Blockquote- oder Listeneintrag, auch
            // wenn kein schließender Marker mehr im Container stand.
            fencedCode = nil
            if let activeHTMLBlock = htmlBlock,
                let htmlCandidate = activeHTMLBlock.content(in: text)
            {
                result += text
                if activeHTMLBlock.ends(in: htmlCandidate) {
                    htmlBlock = nil
                }
                containers.canStartIndentedCode = true
                result += lineEnding(after: line, in: markdown)
                continue
            }
            // Ohne Containerpräfix gehört die aktuelle Zeile zum äußeren Block.
            htmlBlock = nil
            let paragraphWasOpen = !containers.canStartIndentedCode
            let previousContainers = containers
            let context = MarkdownBlockScanner.lineContext(text, containers: &containers)
            let markdownContainerChanged = !containers.hasSameQuoteAndListContext(as: previousContainers)
            if !context.isIndentedCode,
                let openingHTML = MarkdownBlockScanner.openingHTMLBlock(in: context),
                openingHTML.canInterruptParagraph || !paragraphWasOpen
                    || context.startsNewInlineBlock || markdownContainerChanged
            {
                result += text
                if !openingHTML.ends(in: context.content) {
                    htmlBlock = openingHTML
                }
                containers.canStartIndentedCode = true
                result += lineEnding(after: line, in: markdown)
                continue
            }
            if !context.isIndentedCode,
                !paragraphWasOpen || context.startsNewInlineBlock || markdownContainerChanged,
                let definition = try MarkdownReferenceDefinitionScanner.scan(
                    lines, startingAt: lineNumber, firstContext: context, containers: containers,
                    checking: check
                )
            {
                var definitionLines = definition.lines
                let original = String(definition.text[definition.target])
                let decoded = decodedTarget(original)
                targetObserver?(decoded)
                let mapped = mappedTarget(original, mapping: mapping)
                let offset = definition.text.distance(
                    from: definition.text.startIndex, to: definition.target.lowerBound)
                var lineOffset = 0
                for index in definition.contentLines.indices {
                    let content = definition.contentLines[index]
                    if offset >= lineOffset, offset < lineOffset + content.count,
                        let contentRange = definitionLines[index].range(of: content, options: .backwards)
                    {
                        let start = definitionLines[index].index(
                            contentRange.lowerBound, offsetBy: offset - lineOffset)
                        let end = definitionLines[index].index(start, offsetBy: original.count)
                        if let mapped, let replacementObserver, mapped != original {
                            let originalLine = lines[lineNumber + index]
                            let globalStart = originalLine.index(
                                originalLine.startIndex,
                                offsetBy: definitionLines[index].distance(
                                    from: definitionLines[index].startIndex, to: start))
                            let globalEnd = originalLine.index(globalStart, offsetBy: original.count)
                            replacementObserver(globalStart..<globalEnd, mapped)
                        }
                        definitionLines[index].replaceSubrange(start..<end, with: mapped ?? original)
                        break
                    }
                    lineOffset += content.count + 1
                }
                for (offset, definitionLine) in definitionLines.enumerated() {
                    result += definitionLine
                    if offset + 1 < definitionLines.count {
                        result += lineEnding(after: lines[lineNumber + offset], in: markdown)
                    }
                }
                let lastLine = lineNumber + definitionLines.count - 1
                consumedLine = lastLine
                containers = definition.containers
                containers.canStartIndentedCode = true
                result += lineEnding(after: lines[lastLine], in: markdown)
                continue
            }
            if context.isIndentedCode {
                result += text
                containers.canStartIndentedCode = true
            } else if let fence = MarkdownBlockScanner.openingFence(in: context) {
                result += text
                fencedCode = fence
                containers.canStartIndentedCode = true
            } else {
                let rewritten = try rewriteInlineBlock(
                    lines, startingAt: lineNumber, in: markdown,
                    firstContext: context, containers: containers,
                    mapping: mapping, targetObserver: targetObserver,
                    replacementObserver: replacementObserver, check: check
                )
                result += rewritten.text
                consumedLine = rewritten.lastLine
                containers = rewritten.containers
                result += lineEnding(after: lines[rewritten.lastLine], in: markdown)
                continue
            }
            result += lineEnding(after: line, in: markdown)
        }
        return result
    }

    private static func lineEnding(after line: Substring, in markdown: String) -> Substring {
        guard line.endIndex < markdown.endIndex else { return markdown[markdown.endIndex...] }
        return markdown[line.endIndex..<markdown.index(after: line.endIndex)]
    }

    /// Ein Inlineblock wird einmal ohne Container-Präfixe gescannt. Nur die
    /// Zielbereiche werden anschließend im Original ersetzt; Zitatmarker,
    /// Einzüge, Umbrüche und Titel bleiben dadurch bytegleich erhalten.
    private static func rewriteInlineBlock(
        _ lines: [Substring], startingAt firstLine: Int, in markdown: String,
        firstContext: MarkdownBlockScanner.LineContext,
        containers initialContainers: MarkdownBlockScanner.Containers,
        mapping: [String: String], targetObserver: ((String) -> Void)?,
        replacementObserver: ((Range<String.Index>, String) -> Void)?, check: () throws -> Void
    ) rethrows -> (text: String, lastLine: Int, containers: MarkdownBlockScanner.Containers) {
        var contents = [firstContext.content]
        var originalStarts = [
            lines[firstLine].index(lines[firstLine].endIndex, offsetBy: -firstContext.content.count)
        ]
        var containers = initialContainers
        containers.canStartIndentedCode = firstContext.isBlank || !firstContext.allowsParagraphContinuation
        var lastLine = firstLine
        if firstContext.allowsParagraphContinuation {
            while lastLine + 1 < lines.count {
                try check()
                let next = lines[lastLine + 1]
                var nextContainers = containers
                let context = MarkdownBlockScanner.lineContext(String(next), containers: &nextContainers)
                let changed = !containers.hasSameQuoteAndListContext(as: nextContainers)
                let html = MarkdownBlockScanner.openingHTMLBlock(in: context)
                let interruptsWithHTML =
                    !context.isIndentedCode
                    && (html?.canInterruptParagraph == true || (html != nil && changed))
                if context.isBlank || context.startsNewInlineBlock
                    || MarkdownBlockScanner.openingFence(in: context) != nil || interruptsWithHTML
                {
                    break
                }
                contents.append(context.content)
                originalStarts.append(next.index(next.endIndex, offsetBy: -context.content.count))
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
        try MarkdownInlineLinkScanner.scan(logical, checking: check) { range in
            let target = String(logical[range])
            targetObserver?(decodedTarget(target))
            guard let replacement = mappedTarget(target, mapping: mapping), replacement != logical[range]
            else { return }
            while segment + 1 < segments.count, range.lowerBound >= segments[segment].endIndex {
                segment += 1
                logicalCursor = segments[segment].startIndex
                originalCursor = originalStarts[segment]
            }
            guard range.lowerBound >= logicalCursor, range.upperBound <= segments[segment].endIndex else {
                return
            }
            let start = markdown.index(
                originalCursor, offsetBy: logical.distance(from: logicalCursor, to: range.lowerBound))
            let end = markdown.index(
                start, offsetBy: logical.distance(from: range.lowerBound, to: range.upperBound))
            edits.append((start..<end, replacement))
            logicalCursor = range.upperBound
            originalCursor = end
        }
        var output = ""
        var cursor = lines[firstLine].startIndex
        for edit in edits {
            try check()
            replacementObserver?(edit.range, edit.replacement)
            output += markdown[cursor..<edit.range.lowerBound]
            output += edit.replacement
            cursor = edit.range.upperBound
        }
        output += markdown[cursor..<lines[lastLine].endIndex]
        return (output, lastLine, containers)
    }

    /// Derselbe Scanner sammelt und ersetzt Ziele. Beispiele in Code und HTML
    /// zählen daher beim Ressourcenlimit nicht mit.
    static func resourceCandidates(
        in markdown: String,
        maximum: Int,
        sourceDescription: String = "input",
        checking check: () throws -> Void
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
        if exceeded {
            throw ImportFailure("\(sourceDescription) exceeds \(maximum) Markdown resource targets")
        }
        return targets
    }

    private static func mappedTarget(_ target: String, mapping: [String: String]) -> String? {
        if let mapped = mapping[target] { return mapped }
        let decoded = decodedTarget(target)
        if let mapped = mapping[decoded] {
            return mapped.hasPrefix("#") ? mapped : percentEncodedPath(mapped)
        }
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
                target[next].isPunctuation || target[next].isSymbol
            {
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
                        let number = UInt32(digits, radix: hex ? 16 : 10)
                    {
                        value =
                            UnicodeScalar(number).flatMap { $0.value == 0 ? nil : String($0) } ?? "\u{FFFD}"
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
        return
            path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: allowed)
                    ?? String(component)
            }
            .joined(separator: "/")
    }
}
