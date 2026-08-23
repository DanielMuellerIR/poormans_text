import Foundation

/// Schützt aus Quelldokumenten stammenden Text davor, im Ergebnis neue
/// Markdown-Struktur zu bilden. Adapter geben nur bewusst erzeugte Struktur
/// (Überschriften, Bilder und Abschnitte) als Markdown aus.
enum MarkdownEscaping {
    static func literalBlock(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let escaped = String(line)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "_", with: "\\_")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "<", with: "\\<")
                .replacingOccurrences(of: ">", with: "\\>")
                .replacingOccurrences(of: "|", with: "\\|")
            return escapingBlockMarker(in: escaped)
        }.joined(separator: "\n")
    }

    static func heading(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        let escaped = "\\`*_[]<>&#"
        return String(singleLine.flatMap { character -> [Character] in
            escaped.contains(character) ? ["\\", character] : [character]
        })
    }

    private static func escapingBlockMarker(in line: String) -> String {
        let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indentation.count)
        guard let first = body.first else { return line }
        if "#+-".contains(first) || first == ">" {
            return indentation + "\\" + body
        }
        if first.isNumber,
           let period = body.firstIndex(of: "."),
           body[..<period].allSatisfy(\.isNumber),
           body.index(after: period) < body.endIndex,
           body[body.index(after: period)].isWhitespace {
            return indentation + body[..<period] + "\\" + body[period...]
        }
        return line
    }
}
