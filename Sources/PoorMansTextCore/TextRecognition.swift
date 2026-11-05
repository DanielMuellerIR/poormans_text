import Foundation

/// Ergebnis einer lokalen Texterkennung. Unsichere Zeilen bleiben sichtbar,
/// damit der Nutzer sie im Kontext des erhaltenen Originalbildes prüfen kann.
struct TextRecognition: Sendable {
    let text: String
    let lines: [RecognizedTextLine]
}

struct RecognizedTextLine: Sendable {
    /// Wie die Zeile im Markdown steht — bei geringer Konfidenz mit dem
    /// Hinweis in Klammern.
    let text: String
    /// Was das OCR-Backend tatsächlich gelesen hat, ohne Hinweis. Der
    /// Dublettenvergleich braucht diesen Wert: Mit dem dekorierten Text
    /// traf er eine unsichere Zeile nie, und derselbe Satz stand danach
    /// zweimal im Markdown (Review-Fund 2026-09-10).
    let recognized: String
    let bounds: CGRect

    init(text: String, recognized: String? = nil, bounds: CGRect) {
        self.text = text
        self.recognized = recognized ?? text
        self.bounds = bounds
    }
}

// Bestehende interne Aufrufer behalten während der Plattformtrennung ihren Typnamen.
typealias VisionTextRecognition = TextRecognition
