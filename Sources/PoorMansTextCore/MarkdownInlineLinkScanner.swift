import Foundation

enum MarkdownInlineLinkScanner {
    /// Indexiert jeden Backtick-Lauf einmal. Eine binäre Suche beantwortet
    /// danach für jeden möglichen Öffner, ob vor der Absatzgrenze ein gleich
    /// langer Abschluss folgt; kein Absatzrest wird pro Zeile erneut gescannt.
    private struct BacktickRunIndex {
        private let startsByLength: [Int: [String.Index]]

        init(_ markdown: String, check: () throws -> Void) rethrows {
            var starts = [Int: [String.Index]]()
            var index = markdown.startIndex
            var scanned = 0
            while index < markdown.endIndex {
                if scanned % 1_024 == 0 { try check() }
                scanned += 1
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

    /// Indizes für mögliche Titelabschlüsse und das zugehörige Linkende.
    /// Auch unvollständige Links müssen denselben Titel nicht erneut lesen.
    private struct TitleBoundaryIndex {
        var boundaries: [Character: [String.Index]] = [:]
        var linkEnds: [String.Index: String.Index] = [:]

        init(_ text: String, check: () throws -> Void) rethrows {
            var escaped = false
            var scanned = 0
            var pendingBoundary: String.Index?
            for index in text.indices {
                if scanned % 1_024 == 0 { try check() }
                scanned += 1
                let character = text[index]
                if !MarkdownLinkDestination.isWhitespace(character), let boundary = pendingBoundary {
                    if character == ")" { linkEnds[boundary] = text.index(after: index) }
                    pendingBoundary = nil
                }
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "(" {
                    // Ein Klammer-Titel darf vor seinem Abschluss keine weitere
                    // unmaskierte öffnende Klammer enthalten (CommonMark 6.3).
                    boundaries[")", default: []].append(index)
                } else if character == "\"" || character == "'" || character == ")" {
                    boundaries[character, default: []].append(index)
                    pendingBoundary = index
                }
            }
        }

        func linkEnd(_ delimiter: Character, after start: String.Index) -> String.Index? {
            guard let positions = boundaries[delimiter] else { return nil }
            var lower = 0
            var upper = positions.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if positions[middle] <= start { lower = middle + 1 } else { upper = middle }
            }
            return lower < positions.count ? linkEnds[positions[lower]] : nil
        }
    }

    // HTML-Attribute und Tags behalten die ICU-Zeichenklassen.
    private static let inlineHTML = try? NSRegularExpression(pattern:
        #"<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[[\s\S]*?\]\]>|<![A-Z][^>]*>|</[A-Za-z][A-Za-z0-9-]*\s*>|<[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:[^\s\"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*/?>"#)

    static func scan(
        _ line: String, checking check: () throws -> Void,
        onTarget: (Range<String.Index>) -> Void
    ) rethrows {
        // Ohne den HTML-Scanner bleiben Inlineblöcke unangetastet, damit
        // Zeichenfolgen in Attributen nicht als Markdown-Ziele gelten.
        guard let inlineHTML else { return }
        let backtickIndex = try BacktickRunIndex(line, check: check)
        let parentheses = try MarkdownLinkDestination.ParenthesisIndex(line, check: check)
        let titles = try TitleBoundaryIndex(line, check: check)
        let lastCommentClose = line.range(of: "-->", options: .backwards)?.lowerBound
        let lastProcessingClose = line.range(of: "?>", options: .backwards)?.lowerBound
        let lastCDATAClose = line.range(of: "]]>", options: .backwards)?.lowerBound
        try check()
        var index = line.startIndex
        var scanned = 0
        var inlineCodeTicks: Int?
        var brackets: [(isImage: Bool, generation: Int)] = []
        var linkGeneration = 0
        while index < line.endIndex {
            if scanned % 1_024 == 0 { try check() }
            scanned += 1
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
                    before: line.endIndex
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
            if character == "!" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "[" {
                    brackets.append((true, linkGeneration))
                    index = line.index(after: next)
                    continue
                }
            }
            if character == "[" {
                brackets.append((false, linkGeneration))
            } else if character == "]", let opening = brackets.popLast() {
                guard opening.isImage || opening.generation == linkGeneration else {
                    index = line.index(after: index)
                    continue
                }
                let openingParenthesis = line.index(after: index)
                if openingParenthesis < line.endIndex,
                   line[openingParenthesis] == "(",
                   let destination = try MarkdownLinkDestination.parse(
                    in: line, from: line.index(after: openingParenthesis), parentheses: parentheses, check: check
                   ),
                   let linkEnd = inlineLinkEnd(in: line, afterPath: destination.range.upperBound,
                                               usesAngles: destination.usesAngles, titles: titles) {
                    onTarget(destination.range)
                    // Ein Link deaktiviert frühere Linköffner, Bilder dürfen
                    // weiterhin Links enthalten. Die Generation vermeidet einen
                    // erneuten Stapeldurchlauf pro verschachteltem Link.
                    if !opening.isImage { linkGeneration += 1 }
                    index = linkEnd
                    continue
                }
            }
            index = line.index(after: index)
        }
    }

    /// Konsumiert den optionalen Linktitel als Teil derselben Syntaxeinheit.
    /// Backticks in `"Titel`"` sind kein Inline-Code und dürfen den Scanner für
    /// nachfolgende echte Links nicht in einen falschen Zustand versetzen.
    private static func inlineLinkEnd(
        in line: String,
        afterPath pathEnd: String.Index,
        usesAngles: Bool, titles: TitleBoundaryIndex
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
        while index < line.endIndex, MarkdownLinkDestination.isWhitespace(line[index]) {
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
        return titles.linkEnd(closer, after: index)
    }
}

enum MarkdownLinkDestination {
    static func isWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r" || character == "\r\n"
    }

    private static func isDestinationBoundary(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7F }
    }

    fileprivate struct ParenthesisIndex {
        var matchingClose: [String.Index: String.Index] = [:]

        init(_ text: String, check: () throws -> Void) rethrows {
            var stack: [String.Index] = []
            var cursor = text.startIndex
            var scanned = 0
            while cursor < text.endIndex {
                if scanned % 1_024 == 0 { try check() }
                scanned += 1
                let character = text[cursor]
                if character == "\\" {
                    let next = text.index(after: cursor)
                    if next < text.endIndex, text[next].isASCII, text[next].isPunctuation || text[next].isSymbol {
                        cursor = text.index(after: next)
                        continue
                    }
                }
                if isDestinationBoundary(character) { stack.removeAll(keepingCapacity: true) }
                else if character == "(" { stack.append(cursor) }
                else if character == ")", let opening = stack.popLast() { matchingClose[opening] = cursor }
                cursor = text.index(after: cursor)
            }
        }
    }

    static func parse(in text: String, from start: String.Index) -> (range: Range<String.Index>, usesAngles: Bool)? {
        parse(in: text, from: start, parentheses: nil, check: {})
    }

    fileprivate static func parse(
        in text: String, from start: String.Index, parentheses: ParenthesisIndex?, check: () throws -> Void
    ) rethrows -> (range: Range<String.Index>, usesAngles: Bool)? {
        var index = start
        while index < text.endIndex, isWhitespace(text[index]) { index = text.index(after: index) }
        let angles = index < text.endIndex && text[index] == "<"
        if angles { index = text.index(after: index) }
        let pathStart = index
        var depth = 0
        var scanned = 0
        while index < text.endIndex {
            if scanned % 1_024 == 0 { try check() }
            scanned += 1
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
                if isDestinationBoundary(character) { break }
            }
            index = text.index(after: index)
        }
        guard !angles, depth == 0, index > pathStart else { return nil }
        return (pathStart..<index, false)
    }
}
