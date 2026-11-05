import Foundation
#if os(macOS)
import Vision
#endif

/// Löst Sprachkürzel gegen das lokale OCR-Backend auf. Eine leere Auswahl
/// bleibt leer: Vision erkennt die Sprache automatisch, Tesseract verwendet
/// seinen dokumentierten lokalen Standard. Es wird nichts heruntergeladen.
public enum OCRLanguageSelection {
    public static func resolve(_ languages: [String]) throws -> [String] {
        guard !languages.isEmpty else { return [] }
        guard languages.count <= 8 else { throw SelectionError("Choose at most eight OCR languages.") }
        #if os(macOS)
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
        #elseif os(Linux)
        return try LinuxOCR.resolveLanguages(languages, available: LinuxOCR.availableLanguages())
        #else
        throw PlatformBackendUnavailable("OCR language selection")
        #endif
    }

    public struct SelectionError: LocalizedError, Sendable {
        public let reason: String
        init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { reason }
    }
}
