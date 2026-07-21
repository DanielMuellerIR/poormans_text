import Foundation

/// Bereinigt typische Pandoc-Artefakte, ohne den eigentlichen Inhalt zu verändern.
enum MarkdownNormalizer {
    static func normalize(
        _ markdown: String,
        joinsAdjacentPlainLines: Bool = true
    ) -> String {
        let unified = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let keepsFinalNewline = unified.hasSuffix("\n")
        var lines = unified.components(separatedBy: "\n")
        if keepsFinalNewline {
            lines.removeLast()
        }

        var transformed = [String]()
        transformed.reserveCapacity(lines.count)
        var fence: Fence?

        for line in lines {
            if let delimiter = fenceDelimiter(in: line) {
                transformed.append(line)
                if let currentFence = fence {
                    if delimiter.character == currentFence.character,
                       delimiter.length >= currentFence.length {
                        fence = nil
                    }
                } else {
                    fence = delimiter
                }
                continue
            }

            if fence != nil {
                transformed.append(line)
            } else {
                transformed.append(normalizeLine(line))
            }
        }

        let compacted = compactPandocParagraphSpacing(
            transformed,
            joinsAdjacentPlainLines: joinsAdjacentPlainLines
        )
        let result = compacted.joined(separator: "\n")
        return keepsFinalNewline ? result + "\n" : result
    }

    private static func normalizeLine(_ line: String) -> String {
        if isEmphasizedBullet(line) {
            return indentation(of: line) + "-"
        }

        if hasPandocHardBreak(line) {
            let content = String(line.dropLast())
            let visibleContent = content.trimmingCharacters(in: .whitespaces)
            if visibleContent.allSatisfy({ $0 == "*" || $0 == "_" }) {
                return "  "
            }
            return content.trimmingTrailingSpaces() + "  "
        }

        if let separator = unescapedSeparator(line) {
            return separator
        }

        return unescapeLeadingHyphen(line)
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
        joinsAdjacentPlainLines: Bool
    ) -> [String] {
        var result = [String]()
        result.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            guard line.isEmpty,
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
            if joinsAdjacentPlainLines,
               shouldJoinWithHardBreak(previous: previous, next: next) {
                result[result.count - 1] = previous.trimmingTrailingSpaces() + "  "
                continue
            }

            result.append(line)
        }

        return result
    }

    private static func shouldJoinWithHardBreak(previous: String, next: String) -> Bool {
        let previousText = previous.trimmingCharacters(in: .whitespaces)
        guard !previousText.hasSuffix(":"), isPlainTextLine(previous), isPlainTextLine(next) else {
            return false
        }
        return true
    }

    private static func isPlainTextLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != "-" else {
            return false
        }
        let markdownSyntax = CharacterSet(charactersIn: "*_[]!`#<>=|\\")
        return text.rangeOfCharacter(from: markdownSyntax) == nil
    }

    private static func isWhitespaceHardBreak(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func indentation(of line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    private static func fenceDelimiter(in line: String) -> Fence? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let character = trimmed.first, character == "`" || character == "~" else {
            return nil
        }
        let length = trimmed.prefix(while: { $0 == character }).count
        guard length >= 3 else {
            return nil
        }
        return Fence(character: character, length: length)
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
