#if os(Linux)
import Foundation
import CPMTLinux

/// Lokale Standard-OCR. Eingaben werden vor Tesseract vollständig als begrenzte
/// PNGs geprüft; Sprachmodelle stammen ausschließlich aus der Hostinstallation.
enum LinuxOCR {
    static let executable = URL(fileURLWithPath: "/usr/bin/tesseract")

    static func availableLanguages() throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PlatformBackendUnavailable("local Tesseract OCR")
        }
        return try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let result = try ProcessRunner.run(executable: executable, arguments: ["--list-langs"],
                currentDirectory: directory, captureStandardOutput: true,
                timeout: min(10, ConversionExecution.current?.processTimeout ?? 10),
                maximumCapturedBytes: 65_536, writeScope: directory)
            guard result.status == 0 else { throw PlatformBackendUnavailable("installed Tesseract language data") }
            return result.standardOutput.split(whereSeparator: \.isNewline).dropFirst().map(String.init).filter {
                !$0.isEmpty && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
            }.sorted()
        }
    }

    static func resolveLanguages(_ languages: [String], available: [String]) throws -> [String] {
        guard languages.count <= 8 else { throw OCRLanguageSelection.SelectionError("Choose at most eight OCR languages.") }
        let installed = available.filter { $0 != "osd" }
        guard !installed.isEmpty else { throw PlatformBackendUnavailable("installed Tesseract recognition language data") }
        if languages.isEmpty { return installed.contains("eng") ? ["eng"] : [installed[0]] }
        let aliases = ["de": "deu", "en": "eng", "fr": "fra", "es": "spa", "it": "ita", "pt": "por", "nl": "nld", "ru": "rus", "uk": "ukr", "pl": "pol", "tr": "tur", "cs": "ces", "sv": "swe", "da": "dan", "fi": "fin", "no": "nor", "ja": "jpn", "ko": "kor", "ar": "ara", "zh": "chi_sim"]
        var resolved = [String]()
        for language in languages {
            let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw OCRLanguageSelection.SelectionError("Invalid OCR language: \(language)")
            }
            let parts = key.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty }), let first = parts.first else {
                throw OCRLanguageSelection.SelectionError("Invalid OCR language: \(language)")
            }
            let base = String(first)
            let candidate: String
            if base == "zh" {
                if parts.contains("hant") { candidate = "chi_tra" }
                else if parts.contains("hans") { candidate = "chi_sim" }
                else { candidate = parts.contains("tw") || parts.contains("hk") ? "chi_tra" : "chi_sim" }
            } else {
                candidate = aliases[key] ?? aliases[base] ?? key
            }
            guard installed.contains(candidate) else {
                throw OCRLanguageSelection.SelectionError("OCR language \(language) is not installed. Available: \(installed.joined(separator: ", "))")
            }
            if !resolved.contains(candidate) { resolved.append(candidate) }
        }
        return resolved
    }

    static func recognize(pngURL: URL, languages: [String] = []) throws -> TextRecognition {
        try ConversionExecution.check()
        let available = try availableLanguages()
        let selected = try resolveLanguages(languages, available: available)
        return try OCRConcurrencyGate.shared.withPermit {
            try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
                let source = directory.appendingPathComponent("source.png")
                try VerifiedFileStaging.stage(from: pngURL, to: source, maximumBytes: 256 * 1024 * 1024,
                                               describedAs: "the local OCR raster")
                let bytes = try Data(contentsOf: source)
                let dimensions = try validatedDimensions(bytes)
                let result = try ProcessRunner.run(executable: executable,
                    arguments: [source.path, "stdout", "-l", selected.joined(separator: "+"),
                                "--psm", available.contains("osd") ? "1" : "3", "tsv"],
                    currentDirectory: directory, captureStandardOutput: true,
                    timeout: ConversionExecution.current?.processTimeout ?? 30,
                    maximumCapturedBytes: 16 * 1024 * 1024, writeScope: directory)
                guard result.status == 0 else {
                    throw ConversionError.fileSystemFailure("local Tesseract OCR failed: \(result.standardError)")
                }
                return try parseTSV(result.standardOutput, width: dimensions.width, height: dimensions.height)
            }
        }
    }

    private static func validatedDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count >= 24, data.prefix(8) == Data([137,80,78,71,13,10,26,10]) else {
            throw RasterImageValidationError.invalid
        }
        func number(_ offset: Int) -> Int { data[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) } }
        let width = number(16), height = number(20)
        guard width > 0, height > 0, height <= 16_000_000, width <= 16_000_000 / height else {
            throw RasterImageValidationError.exceedsLimits
        }
        var info = pmt_image_info()
        let status = data.withUnsafeBytes { pmt_validate_png($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &info) }
        guard status == PMT_IMAGE_OK, Int(info.width) == width, Int(info.height) == height else {
            throw RasterImageValidationError.invalid
        }
        return (width, height)
    }

    static func parseTSV(_ text: String, width: Int, height: Int) throws -> TextRecognition {
        guard width > 0, height > 0 else { throw RasterImageValidationError.invalid }
        var lines = [RecognizedTextLine]()
        var words = [String]()
        var bounds = CGRect.null
        var confidence = 0.0
        var count = 0
        var previousKey: String?
        var sawPage = false
        var totalWords = 0
        func finish() {
            guard !words.isEmpty else { return }
            let recognized = words.joined(separator: " ")
            let uncertain = confidence / Double(count) < 55
            lines.append(RecognizedTextLine(text: uncertain ? "[OCR uncertain: \(recognized)]" : recognized,
                recognized: recognized, bounds: CGRect(x: bounds.minX / Double(width),
                y: 1 - bounds.maxY / Double(height), width: bounds.width / Double(width), height: bounds.height / Double(height))))
            words = []; bounds = .null; confidence = 0; count = 0
        }
        let rows = text.split(whereSeparator: \.isNewline)
        guard rows.first?.hasPrefix("level\tpage_num\t") == true else {
            throw ConversionError.fileSystemFailure("the OCR TSV header is invalid")
        }
        for row in rows.dropFirst() {
            try ConversionExecution.check()
            let columns = row.split(separator: "\t", maxSplits: 11, omittingEmptySubsequences: false)
            guard columns.count == 12, let level = Int(columns[0]),
                  let x = Int(columns[6]), let y = Int(columns[7]), let w = Int(columns[8]), let h = Int(columns[9]),
                  x >= 0, y >= 0, w >= 0, h >= 0, x <= width, y <= height, w <= width - x, h <= height - y else {
                throw ConversionError.fileSystemFailure("the OCR TSV geometry is invalid")
            }
            if level == 1 {
                guard !sawPage, x == 0, y == 0, w == width, h == height else {
                    throw ConversionError.fileSystemFailure("the OCR TSV page does not match its raster")
                }
                sawPage = true
            }
            guard level == 5 else { continue }
            guard sawPage, let score = Double(columns[10]), score.isFinite, score >= 0, score <= 100 else {
                throw ConversionError.fileSystemFailure("the OCR TSV word confidence is invalid")
            }
            let word = ExtractedText.normalized(String(columns[11]))
            guard !word.isEmpty else { continue }
            guard w > 0, h > 0, totalWords < 100_000 else {
                throw ConversionError.fileSystemFailure("the OCR TSV word count exceeds its limit")
            }
            let key = columns[1...4].joined(separator: ":")
            if previousKey != key { finish(); previousKey = key }
            words.append(word); bounds = bounds.union(CGRect(x: x, y: y, width: w, height: h)); confidence += score; count += 1; totalWords += 1
        }
        finish()
        guard sawPage else { throw ConversionError.fileSystemFailure("the OCR TSV page is missing") }
        return TextRecognition(text: ExtractedText.normalized(lines.map(\.text).joined(separator: "\n")), lines: lines)
    }
}
#endif
