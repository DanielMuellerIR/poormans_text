import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Ergebnis einer lokalen Vision-Erkennung. Unsichere Zeilen bleiben sichtbar,
/// damit der Nutzer sie im Kontext des erhaltenen Originalbildes prüfen kann.
struct VisionTextRecognition: Sendable {
    let text: String
    let lines: [VisionTextRecognizer.OCRLine]
}

/// Gemeinsame Vision-Konfiguration für Bildimport und PDF-OCR. Beide Wege
/// erkennen nur lokale Pixel und laden keine Inhalte nach.
enum VisionTextRecognizer {
    static func recognize(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        languages: [String] = []
    ) throws -> VisionTextRecognition {
        try ConversionExecution.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = languages.isEmpty
        if !languages.isEmpty { request.recognitionLanguages = languages }
        request.minimumTextHeight = minimumTextHeight
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try OCRConcurrencyGate.shared.withPermit { try handler.perform([request]) }
        try ConversionExecution.check()

        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty else {
                return nil
            }
            let isUncertain = candidate.confidence < minimumConfidence
            let text = isUncertain
                ? "[OCR uncertain: \(candidate.string)]"
                : candidate.string
            return OCRLine(text: text, bounds: observation.boundingBox)
        }
        let ordered = readingOrder(lines)
        return VisionTextRecognition(text: normalizedText(ordered.map(\.text).joined(separator: "\n")), lines: ordered)
    }

    /// Leserichtung: erst oben nach unten in Baender, dann in jedem Band links
    /// nach rechts.
    ///
    /// Frueher entschied ein einziger Comparator beides — bei einem Y-Abstand
    /// bis zur Toleranz verglich er X, sonst Y. Das ist KEINE strikte schwache
    /// Ordnung: Fuer drei Zeilen mit den Y-Werten 0, 0.01 und 0.02 und
    /// steigendem X gilt A < B, B < C und zugleich C < A. `sorted(by:)` darf
    /// darauf mit einer beliebigen Reihenfolge antworten, obwohl Bild- und
    /// PDF-Import ausdruecklich top-down und links-nach-rechts zusagen
    /// (Review-Fund 2026-08-25).
    ///
    /// Jetzt in zwei transitiven Schritten: streng nach Y sortieren, dann
    /// Baender bilden — ein Band endet, sobald eine Zeile weiter als die
    /// Toleranz von der ERSTEN Zeile des Bandes entfernt liegt — und jedes Band
    /// nach X sortieren. Die feste Bezugszeile je Band ist der Punkt: Ohne sie
    /// koennte sich ein Band ueber eine ganze Seite fortschleppen, weil jede
    /// Zeile nur mit ihrem Vorgaenger verglichen wird.
    static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let topDown = lines.sorted { lhs, rhs in
            if lhs.bounds.midY != rhs.bounds.midY {
                return lhs.bounds.midY > rhs.bounds.midY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        var ordered: [OCRLine] = []
        var band: [OCRLine] = []
        var reference: CGFloat = 0
        for line in topDown {
            if band.isEmpty {
                reference = line.bounds.midY
            } else if reference - line.bounds.midY > lineGroupingTolerance {
                ordered.append(contentsOf: leftToRight(band))
                band.removeAll()
                reference = line.bounds.midY
            }
            band.append(line)
        }
        ordered.append(contentsOf: leftToRight(band))
        return ordered
    }

    private static func leftToRight(_ band: [OCRLine]) -> [OCRLine] {
        band.sorted { lhs, rhs in
            if lhs.bounds.minX != rhs.bounds.minX {
                return lhs.bounds.minX < rhs.bounds.minX
            }
            return lhs.bounds.midY > rhs.bounds.midY
        }
    }

    private static func normalizedText(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let safeScalars = unified.unicodeScalars.filter {
            $0.value == 0x0A || $0.value == 0x09 || $0.value >= 0x20 && $0.value != 0x7F
        }
        return String(String.UnicodeScalarView(safeScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let minimumTextHeight: Float = 0.008
    private static let minimumConfidence: Float = 0.55
    private static let lineGroupingTolerance: CGFloat = 0.015

    struct OCRLine: Sendable {
        let text: String
        let bounds: CGRect
    }
}
