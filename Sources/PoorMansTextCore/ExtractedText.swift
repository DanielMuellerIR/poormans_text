import Foundation

/// Text, der aus einem fremden Dokument gelesen wurde, für die Markdown-Ausgabe
/// bereinigt.
///
/// PDFKit und Vision liefern beide Zeilenenden in allen drei Schreibweisen und
/// gelegentlich Steuerzeichen aus der Schriftkodierung. Beide Leser brauchen
/// dieselbe Bereinigung; sie stand vorher wortgleich zweimal im Kern
/// (Review-Fund 2026-09-10).
enum ExtractedText {
    /// Zeilenenden vereinheitlichen, Steuerzeichen außer Tabulator und
    /// Zeilenvorschub verwerfen, Ränder kürzen.
    static func normalized(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let safeScalars = unified.unicodeScalars.filter {
            $0.value == 0x0A || $0.value == 0x09 || $0.value >= 0x20 && $0.value != 0x7F
        }
        return String(String.UnicodeScalarView(safeScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
