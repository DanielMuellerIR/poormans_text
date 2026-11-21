import Foundation

enum MarkdownReferenceDefinitionScanner {
    struct Definition {
        let text: String
        let lines: [String]
        let contentLines: [String]
        let target: Range<String.Index>
        let containers: MarkdownBlockScanner.Containers
    }

    static func scan(
        _ lines: [Substring], startingAt lineNumber: Int, firstContext: MarkdownBlockScanner.LineContext,
        containers initialContainers: MarkdownBlockScanner.Containers, checking check: () throws -> Void
    ) rethrows -> Definition? {
        var definitionText = firstContext.content
        var definitionLines = [String(lines[lineNumber])]
        var contentLines = [firstContext.content]
        var continuationContainers = initialContainers
        var definition = parse(in: definitionText)
        while definition?.needsContinuation == true,
              lineNumber + definitionLines.count < lines.count {
            try check()
            let nextText = String(lines[lineNumber + definitionLines.count])
            guard let content = continuationContent(nextText, within: initialContainers,
                                                    scanning: &continuationContainers) else { break }
            definitionLines.append(nextText)
            contentLines.append(content)
            definitionText += "\n" + content
            if let delimiter = definition?.delimiter {
                // Lange Titel nur am möglichen Ende erneut parsen; sonst
                // würde jede Fortsetzungszeile den gesamten Titel lesen.
                let hasBoundary = hasUnescapedBoundary(in: content, delimiter: delimiter)
                if !hasBoundary {
                    if delimiter == "]", definitionText.count > 1_003 { break }
                    continue
                }
            }
            definition = parse(in: definitionText)
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
                try check()
                let next = String(lines[lineNumber + definitionLines.count + titleLines.count])
                guard let content = continuationContent(next, within: initialContainers,
                                                        scanning: &titleContainers) else { break }
                if titleLines.isEmpty {
                    let title = content.trimmingCharacters(in: .whitespaces)
                    guard let first = title.first, ["\"", "'", "("].contains(String(first)) else { break }
                    titleDelimiter = first == "(" ? ")" : first
                }
                titleLines.append(next)
                titleContents.append(content)
                probe += "\n" + content
                // Erst mögliche Abschlusszeilen prüfen, damit lange Titel linear gelesen werden.
                if titleLines.count > 1, let delimiter = titleDelimiter,
                   !hasUnescapedBoundary(in: content, delimiter: delimiter) { continue }
                guard let parsed = parse(in: probe) else { break }
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
        guard let target = definition?.target else { return nil }
        return Definition(text: definitionText, lines: definitionLines,
                          contentLines: contentLines, target: target, containers: continuationContainers)
    }

    private static func continuationContent(
        _ line: String, within initial: MarkdownBlockScanner.Containers,
        scanning containers: inout MarkdownBlockScanner.Containers
    ) -> String? {
        let context = MarkdownBlockScanner.lineContext(line, containers: &containers)
        guard !context.isBlank,
              (!context.startsNewInlineBlock || context.isIndentedCode),
              MarkdownBlockScanner.openingFence(in: context) == nil,
              MarkdownBlockScanner.openingHTMLBlock(in: context)?.canInterruptParagraph != true,
              containers.hasSameQuoteAndListContext(as: initial) else { return nil }
        return context.content
    }

    private static func parse(in text: String) -> (target: Range<String.Index>?, needsContinuation: Bool, delimiter: Character?)? {
        let indent = MarkdownBlockScanner.leadingIndentation(in: text[...])
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
        if let target = referenceDestination(in: text, from: cursor) { return (target, false, nil) }
        if text[cursor...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (nil, true, nil) }
        guard let target = MarkdownLinkDestination.parse(in: text, from: cursor) else { return nil }
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

    private static func referenceDestination(in text: String, from start: String.Index) -> Range<String.Index>? {
        guard let target = MarkdownLinkDestination.parse(in: text, from: start) else { return nil }
        var end = target.range.upperBound
        if target.usesAngles { end = text.index(after: end) }
        if end == text.endIndex { return target.range }
        guard MarkdownLinkDestination.isWhitespace(text[end]) else { return nil }
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

    private static func hasUnescapedBoundary(in text: String, delimiter: Character) -> Bool {
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == delimiter || (delimiter == "]" && character == "[")
                || (delimiter == ")" && character == "(") { return true }
        }
        return false
    }

}
