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

        var transformed = [String]()
        transformed.reserveCapacity(lines.count)
        var fence: Fence?

        for line in lines {
            if let currentFence = fence {
                transformed.append(line)
                if isClosingFence(line, matching: currentFence) {
                    fence = nil
                }
                continue
            }

            if let delimiter = openingFence(in: line) {
                transformed.append(line)
                fence = delimiter
                continue
            }

            transformed.append(normalizeLine(line))
        }

        let compacted = compactPandocParagraphSpacing(transformed)
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

    private static func compactPandocParagraphSpacing(_ lines: [String]) -> [String] {
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
