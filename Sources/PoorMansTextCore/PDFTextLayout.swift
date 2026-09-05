import Foundation
import PDFKit

struct PDFTextLine {
    let text: String
    let bounds: CGRect
}

/// Positionsbezogene Textverarbeitung. Sie entfernt keine Wörter: Ein unsicherer
/// Positionslauf fällt auf PDFKit-Text zurück; Layoutverluste bleiben diagnostiziert.
enum PDFTextLayout {
    static func lines(on page: PDFPage) throws -> [PDFTextLine] {
        let text = page.string ?? ""
        func fallback() -> [PDFTextLine] {
            text.isEmpty ? [] : [PDFTextLine(text: text, bounds: page.bounds(for: .mediaBox))]
        }
        guard text.utf16.count <= 100_000, page.rotation == 0, page.numberOfCharacters == text.utf16.count,
              !text.unicodeScalars.contains(where: { (0x590...0x8FF).contains($0.value) || (0xFB1D...0xFEFF).contains($0.value) }) else {
            return fallback()
        }
        var glyphs: [PDFTextLine] = []
        var offset = 0
        var lineReference: CGRect?
        for character in text {
            if offset & 4095 == 0 { try ConversionExecution.check() }
            let value = String(character)
            let length = value.utf16.count
            defer { offset += length }
            if value == "\n" || value == "\r" { lineReference = nil; continue }
            // characterBounds verwendet andere Indizes für synthetische Zeilenwechsel.
            // PDFSelection bindet den NSString-Bereich an denselben Quelltext.
            guard let selection = page.selection(for: NSRange(location: offset, length: length)), selection.string == value else { return fallback() }
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.minX.isFinite, bounds.minY.isFinite else { return fallback() }
            if let reference = lineReference,
               abs(reference.midY - bounds.midY) > max(reference.height, bounds.height) * 0.75 {
                return fallback()
            }
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { lineReference = bounds }
            glyphs.append(PDFTextLine(text: value, bounds: bounds))
        }
        let sorted = glyphs.sorted { $0.bounds.midY == $1.bounds.midY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY > $1.bounds.midY }
        var bands: [[PDFTextLine]] = []
        for glyph in sorted {
            if let last = bands.last?.first,
               abs(last.bounds.midY - glyph.bounds.midY) < max(last.bounds.height, glyph.bounds.height) * 0.45 {
                bands[bands.count - 1].append(glyph)
            } else { bands.append([glyph]) }
        }
        var lines: [PDFTextLine] = []
        for band in bands {
            let glyphs = band.sorted { $0.bounds.minX < $1.bounds.minX }
            var text = ""
            var bounds = CGRect.null
            func finish() {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { lines.append(PDFTextLine(text: value, bounds: bounds)) }
                text = ""
                bounds = .null
            }
            for glyph in glyphs {
                if !bounds.isNull {
                    let gap = glyph.bounds.minX - bounds.maxX
                    if gap > max(12, glyph.bounds.height * 1.5) { finish() }
                }
                text += glyph.text
                bounds = bounds.union(glyph.bounds)
            }
            finish()
        }
        func characters(_ string: String) -> [UInt32: Int] {
            var result: [UInt32: Int] = [:]
            for scalar in string.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                result[scalar.value, default: 0] += 1
            }
            return result
        }
        guard characters(text) == characters(lines.map(\.text).joined()) else { return fallback() }
        return lines
    }

    static func ordered(_ lines: [PDFTextLine], pageBounds: CGRect) -> [PDFTextLine] {
        let sorted = lines.sorted { $0.bounds.midY == $1.bounds.midY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY > $1.bounds.midY }
        let middle = pageBounds.midX
        let gap = pageBounds.width * 0.015
        let left = sorted.filter { $0.bounds.maxX < middle - gap }
        let right = sorted.filter { $0.bounds.minX > middle + gap }
        guard left.count >= 2, right.count >= 2 else { return sorted }
        let spanning = sorted.filter { $0.bounds.maxX >= middle - gap && $0.bounds.minX <= middle + gap }
        var output: [PDFTextLine] = []
        var remainingLeft = left
        var remainingRight = right
        for separator in spanning {
            output += remainingLeft.filter { $0.bounds.midY > separator.bounds.midY }
            output += remainingRight.filter { $0.bounds.midY > separator.bounds.midY }
            remainingLeft.removeAll { $0.bounds.midY > separator.bounds.midY }
            remainingRight.removeAll { $0.bounds.midY > separator.bounds.midY }
            output.append(separator)
        }
        return output + remainingLeft + remainingRight
    }

    /// Wiederkehrend heißt: an mindestens zwei und 60 Prozent der Seiten in
    /// derselben Randzone. Gleichlautender Haupttext bleibt ausdrücklich stehen.
    static func removingRepeatedMargins(_ pages: [[PDFTextLine]], bounds: [CGRect]) -> [[PDFTextLine]] {
        guard pages.count >= 2 else { return pages }
        func key(_ line: PDFTextLine, _ page: CGRect) -> String? {
            let y = (line.bounds.midY - page.minY) / page.height
            guard y >= 0.90 || y <= 0.10 else { return nil }
            return (y >= 0.90 ? "top:" : "bottom:") + line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var occurrences: [String: Int] = [:]
        for (page, bounds) in zip(pages, bounds) {
            for value in Set(page.compactMap { key($0, bounds) }) { occurrences[value, default: 0] += 1 }
        }
        let minimum = max(2, Int(ceil(Double(pages.count) * 0.6)))
        return zip(pages, bounds).map { page, bounds in
            page.filter { line in
                guard let key = key(line, bounds) else { return true }
                return occurrences[key, default: 0] < minimum
            }
        }
    }

    static func text(_ lines: [PDFTextLine], hardHyphens: Bool) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let previous = lines[index - 1].bounds
                let current = line.bounds
                // Niemals eine Trennung über den Spaltenwechsel oder eine große
                // vertikale Lücke hinweg verbinden.
                let adjacent = current.midY < previous.midY && previous.minY - current.maxY < max(previous.height, current.height) * 2
                    && abs(previous.minX - current.minX) < 20
                result += adjacent ? "\n" : "\n\n"
            }
            result += line.text
        }
        return cleanedHyphenation(result, hardHyphens: hardHyphens)
    }

    static func cleanedHyphenation(_ text: String, hardHyphens: Bool) -> String {
        let soft = text.replacingOccurrences(of: "\u{00AD}\n", with: "")
            .replacingOccurrences(of: "\u{00AD}", with: "")
        guard hardHyphens else { return soft }
        // Nur ein langes Kleinbuchstabenwort mit kleinem Folgewort. Zahlen,
        // Großschreibung und kurze Wortteile bleiben unverändert. Heuristik opt-in.
        return soft.replacingOccurrences(of: #"([\p{Ll}]{4,})-\n([\p{Ll}]{3,})"#,
            with: "$1$2", options: .regularExpression)
    }
}
