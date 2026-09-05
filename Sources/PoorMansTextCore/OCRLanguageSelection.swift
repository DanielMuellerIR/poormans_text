import Foundation
import Vision

/// Löst kurze Sprachkürzel gegen die lokal verfügbare Vision-Version auf.
/// Leere Auswahl bedeutet automatische Spracherkennung; es wird nichts geladen.
public enum OCRLanguageSelection {
    public static func resolve(_ languages: [String]) throws -> [String] {
        guard !languages.isEmpty else { return [] }
        guard languages.count <= 8 else { throw SelectionError("Choose at most eight OCR languages.") }
        let supported = try VNRecognizeTextRequest().supportedRecognitionLanguages()
        var resolved: [String] = []
        for language in languages {
            let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 || (48...57).contains($0) }) else {
                throw SelectionError("Invalid OCR language: \(language)")
            }
            let preferred = key == "en" ? "en-US" : key
            guard let match = supported.first(where: { $0.lowercased() == preferred.lowercased() })
                ?? supported.first(where: { $0.lowercased() == key })
                ?? supported.sorted().first(where: { $0.lowercased().hasPrefix(key + "-") }) else {
                throw SelectionError("Unsupported OCR language: \(language). Available: \(supported.joined(separator: ", "))")
            }
            if !resolved.contains(match) { resolved.append(match) }
        }
        return resolved
    }

    public struct SelectionError: LocalizedError, Sendable {
        public let reason: String
        init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { reason }
    }
}
