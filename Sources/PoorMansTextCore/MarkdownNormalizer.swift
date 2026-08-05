import Foundation

/// Bereinigt typische Pandoc-Artefakte, ohne den eigentlichen Inhalt zu verändern.
enum MarkdownNormalizer {
    static func normalize(_ markdown: String) -> String {
        let unified = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let keepsFinalNewline = unified.hasSuffix("\n")
        var lines = unified.components(separatedBy: "\n")
        if keepsFinalNewline {
            lines.removeLast()
        }

        // Erst alle Code-Zeilen markieren, dann aufräumen. Sonst greifen die
        // Aufräumregeln auch in eingerückten Code-Blöcken, und eine Codezeile mit
        // abschließendem Backslash (etwa eine Shell-Fortsetzung) verlöre ihn.
        let isCode = markCodeLines(lines)

        var transformed = [String]()
        transformed.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            let nextLine = index + 1 < lines.count ? lines[index + 1] : nil
            transformed.append(
                isCode[index] ? line : normalizeLine(line, nextLine: nextLine)
            )
        }

        let compacted = compactPandocParagraphSpacing(transformed, isCode: isCode)
        let result = compacted.joined(separator: "\n")
        return keepsFinalNewline ? result + "\n" : result
    }

    /// Markiert jede Zeile, die zu einem Code-Block gehört: eingezäunte Blöcke,
    /// eingerückte Blöcke und die Leerzeilen innerhalb eines eingerückten Blocks.
    ///
    /// Eingerückt heißt hier „vier Spalten jenseits des offenen Listenpunkts".
    /// Ohne diese Buchhaltung wäre jeder tiefer eingerückte Listeneintrag
    /// fälschlich Code. Pandoc schreibt einen Code-Block ohne Sprachangabe immer
    /// eingerückt — auch im GFM-Dialekt —, deshalb ist dieser Fall der Regelfall
    /// und nicht die Ausnahme.
    private static func markCodeLines(_ lines: [String]) -> [Bool] {
        var isCode = [Bool](repeating: false, count: lines.count)
        var fence: Fence?
        var itemIndents = [Int]()

        for (index, line) in lines.enumerated() {
            if let currentFence = fence {
                isCode[index] = true
                if isClosingFence(line, matching: currentFence) {
                    fence = nil
                }
                continue
            }

            // Eine Leerzeile beendet keinen Listenpunkt.
            if isBlank(line) {
                continue
            }

            let indent = indentWidth(of: line)
            while let openItem = itemIndents.last, indent < openItem {
                itemIndents.removeLast()
            }
            let container = itemIndents.last ?? 0

            if indent >= container + 4 {
                isCode[index] = true
                continue
            }

            if let delimiter = openingFence(in: line) {
                isCode[index] = true
                fence = delimiter
                continue
            }

            if let contentIndent = listItemContentIndent(of: line, indent: indent) {
                itemIndents.append(contentIndent)
            }
        }

        // Eine Leerzeile mitten in einem eingerückten Code-Block ist selbst noch
        // Code. Sie wird ja nicht eingerückt geschrieben und ist oben deshalb als
        // Fließtext durchgelaufen; jeder Leerzeilen-Lauf zwischen zwei Code-Zeilen
        // gehört nachträglich dazu.
        var runStart: Int?
        for index in lines.indices {
            if !isCode[index], isBlank(lines[index]) {
                if runStart == nil {
                    runStart = index
                }
                continue
            }
            if let start = runStart {
                if start > 0, isCode[start - 1], isCode[index] {
                    for blank in start..<index {
                        isCode[blank] = true
                    }
                }
                runStart = nil
            }
        }

        return isCode
    }

    /// Die Spalte, in der der Inhalt eines Listenpunkts beginnt — also hinter
    /// Marker und folgendem Leerraum. `nil`, wenn die Zeile kein Listenpunkt ist.
    private static func listItemContentIndent(of line: String, indent: Int) -> Int? {
        var rest = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
        let markerLength: Int

        if let marker = rest.first, marker == "-" || marker == "*" || marker == "+" {
            markerLength = 1
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, digits.count <= 9 else {
                return nil
            }
            rest = rest.dropFirst(digits.count)
            guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else {
                return nil
            }
            markerLength = digits.count + 1
            rest = rest.dropFirst()
        }

        let spacing = rest.prefix(while: { $0 == " " || $0 == "\t" })
        guard !spacing.isEmpty else {
            return nil
        }
        return indent + markerLength + spacing.count
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Ein Tabulator zählt wie vier Spalten — so misst CommonMark Einrückung.
    private static func indentWidth(of line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func normalizeLine(_ line: String, nextLine: String?) -> String {
        if isEmphasizedBullet(line) {
            return indentation(of: line) + "-"
        }

        if hasPandocHardBreak(line) {
            let content = String(line.dropLast())
            let visibleContent = content.trimmingCharacters(in: .whitespaces)
            if visibleContent.allSatisfy({ $0 == "*" || $0 == "_" }) {
                return "  "
            }
            let normalizedContent = content.trimmingTrailingSpaces()
            return hardBreakIsLayoutOnly(before: nextLine)
                ? normalizedContent
                : normalizedContent + "  "
        }

        if let separator = unescapedSeparator(line) {
            return separator
        }

        return unescapeLeadingHyphen(line)
    }

    private static func hardBreakIsLayoutOnly(before nextLine: String?) -> Bool {
        guard let nextLine else {
            return true
        }
        if isBlank(nextLine) {
            return true
        }
        return listItemContentIndent(
            of: nextLine,
            indent: indentWidth(of: nextLine)
        ) != nil
    }

    private static func hasPandocHardBreak(_ line: String) -> Bool {
        line.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
    }

    private static func isEmphasizedBullet(_ line: String) -> Bool {
        let body = line.dropFirst(indentation(of: line).count)
        let unformatted = body.filter { $0 != "*" && $0 != "_" }
        return unformatted.trimmingCharacters(in: markerWhitespace) == "•"
    }

    private static func unescapedSeparator(_ line: String) -> String? {
        let indent = indentation(of: line)
        let body = String(line.dropFirst(indent.count))
        var index = body.startIndex
        var underscores = 0

        while index < body.endIndex {
            guard body[index] == "\\" else {
                return nil
            }
            let underscore = body.index(after: index)
            guard underscore < body.endIndex, body[underscore] == "_" else {
                return nil
            }
            underscores += 1
            index = body.index(after: underscore)
        }

        guard underscores >= 3 else {
            return nil
        }
        return indent + String(repeating: "_", count: underscores)
    }

    private static func unescapeLeadingHyphen(_ line: String) -> String {
        let indent = indentation(of: line)
        let body = line.dropFirst(indent.count)
        guard body.hasPrefix("\\-") else {
            return line
        }
        return indent + body.dropFirst().description
    }

    private static func compactPandocParagraphSpacing(
        _ lines: [String],
        isCode: [Bool]
    ) -> [String] {
        var result = [String]()
        result.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            // Eine Leerzeile innerhalb eines Code-Blocks gehört zum Code und
            // darf nicht wegfallen.
            guard line.isEmpty,
                  !isCode[index],
                  let previous = result.last,
                  index + 1 < lines.count else {
                result.append(line)
                continue
            }

            let next = lines[index + 1]
            if isWhitespaceHardBreak(previous) || isWhitespaceHardBreak(next) {
                continue
            }
            if previous.trimmingCharacters(in: .whitespaces) == "-",
               next.trimmingCharacters(in: .whitespaces) == "-" {
                continue
            }
            result.append(line)
        }

        return result
    }

    private static func isWhitespaceHardBreak(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func indentation(of line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    private static func openingFence(in line: String) -> Fence? {
        guard let trimmed = fenceCandidate(in: line),
              let character = trimmed.first,
              character == "`" || character == "~" else {
            return nil
        }
        let length = trimmed.prefix(while: { $0 == character }).count
        guard length >= 3 else {
            return nil
        }
        let remainder = trimmed.dropFirst(length)
        guard character != "`" || !remainder.contains("`") else {
            return nil
        }
        return Fence(character: character, length: length)
    }

    private static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        guard let trimmed = fenceCandidate(in: line),
              trimmed.first == fence.character else {
            return false
        }
        let length = trimmed.prefix(while: { $0 == fence.character }).count
        guard length >= fence.length else {
            return false
        }
        return trimmed.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// CommonMark erlaubt vor einem Fence höchstens drei Leerzeichen, aber keinen Tab.
    private static func fenceCandidate(in line: String) -> Substring? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else {
            return nil
        }
        let trimmed = line.dropFirst(indentation)
        guard let character = trimmed.first, character == "`" || character == "~" else {
            return nil
        }
        return trimmed
    }

    private static let markerWhitespace: CharacterSet = {
        var whitespace = CharacterSet.whitespaces
        whitespace.insert(charactersIn: "\u{00A0}")
        return whitespace
    }()

    private struct Fence {
        let character: Character
        let length: Int
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        String(reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
    }
}
