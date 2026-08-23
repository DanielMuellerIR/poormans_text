import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Ergebnis einer lokalen Vision-Erkennung. Unsichere Zeilen bleiben sichtbar,
/// damit der Nutzer sie im Kontext des erhaltenen Originalbildes prüfen kann.
struct VisionTextRecognition: Sendable {
    let text: String
}

/// Gemeinsame Vision-Konfiguration für Bildimport und PDF-OCR. Beide Wege
/// erkennen nur lokale Pixel und laden keine Inhalte nach.
enum VisionTextRecognizer {
    static func recognize(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> VisionTextRecognition {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = minimumTextHeight
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try handler.perform([request])

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
        }.sorted { lhs, rhs in
            if abs(lhs.bounds.midY - rhs.bounds.midY) > lineGroupingTolerance {
                return lhs.bounds.midY > rhs.bounds.midY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        return VisionTextRecognition(text: normalizedText(lines.map(\.text).joined(separator: "\n")))
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

    private struct OCRLine {
        let text: String
        let bounds: CGRect
    }
}
