import Foundation

/// Schützt aus Quelldokumenten stammenden Text davor, im Ergebnis neue
/// Markdown-Struktur zu bilden. Adapter geben nur bewusst erzeugte Struktur
/// (Überschriften, Bilder und Abschnitte) als Markdown aus.
enum MarkdownEscaping {
    /// Maskiert Text innerhalb einer bereits vom Renderer erzeugten
    /// Markdown-Struktur. So können Zellwerte weder Links/Bilder noch rohes
    /// HTML oder Hervorhebung bilden; bewusst erzeugte Trenner wie `<br>` fügt
    /// der jeweilige Renderer erst danach ein.
    static func inlineLiteral(_ text: String) -> String {
        let escaped = "\\`*_[]()<>|&!~"
        return String(text.flatMap { character -> [Character] in
            escaped.contains(character) ? ["\\", character] : [character]
        })
    }

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
                .replacingOccurrences(of: "&", with: "\\&")
                .replacingOccurrences(of: "~", with: "\\~")
            let protected = escapingBlockMarker(in: escaped)
            let indentation = protected.prefix(while: { $0 == " " || $0 == "\t" })
            // Zeichenreferenzen erhalten sichtbare Einrückung, ohne einen
            // Codeblock zu öffnen, in dem die Maskierungen wörtlich würden.
            if indentation.contains("\t") || indentation.count >= 4 {
                return indentation.map { $0 == "\t" ? "&#9;" : "&#32;" }.joined()
                    + protected.dropFirst(indentation.count)
            }
            return protected
        }.joined(separator: "\n")
    }

    static func heading(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        let escaped = "\\`*_[]<>&#~"
        return String(singleLine.flatMap { character -> [Character] in
            escaped.contains(character) ? ["\\", character] : [character]
        })
    }

    private static func escapingBlockMarker(in line: String) -> String {
        let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indentation.count)
        guard let first = body.first else { return line }
        // `=` gehört dazu, auch wenn es keinen Block ERÖFFNET: Eine
        // Zeile aus Gleichheitszeichen macht die Zeile DAVOR zur Überschrift
        // (Setext). Tilden sind bereits im gesamten Text maskiert, damit auch
        // Durchstreichung innerhalb einer Zeile keine neue Struktur bildet.
        if "#+-=".contains(first) || first == ">" {
            return indentation + "\\" + body
        }
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        let marker = body.index(body.startIndex, offsetBy: digits.count)
        if (1...9).contains(digits.count), marker < body.endIndex,
           body[marker] == "." || body[marker] == ")",
           body.index(after: marker) < body.endIndex,
           body[body.index(after: marker)].isWhitespace {
            return indentation + digits + "\\" + body[marker...]
        }
        return line
    }
}
