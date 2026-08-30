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
        // `=` und `~` gehören dazu, auch wenn sie keinen Block ERÖFFNEN: Eine
        // Zeile aus Gleichheitszeichen macht die Zeile DAVOR zur Überschrift
        // (Setext), und `~~~` öffnet wie ein Backtick-Fence einen Codeblock,
        // der den folgenden Text verschluckt. Beides kommt in Fremdtext
        // natürlich vor — als unterstrichene Überschrift eines abgetippten
        // Dokuments oder als Trennlinie.
        if "#+-=~".contains(first) || first == ">" {
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
