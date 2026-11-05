#if os(Linux)
import Foundation

// Poppler kann räumlich getrennte Wörter ohne Leerzeichen liefern. Nur deutliche
// Lücken zwischen sichtbaren, vertikal überlappenden Glyphen ergänzen; Zeichen
// und gelieferte Zeilenreihenfolge bleiben erhalten. Das rekonstruiert keine Zellen.
enum LinuxPDFTextGeometry {
    static func lines(text: String, rectangles: [[Double]]) -> [String]? {
        guard rectangles.count == text.unicodeScalars.count,
              !text.unicodeScalars.contains(where: { (0x590...0x8FF).contains($0.value) || (0xFB1D...0xFEFF).contains($0.value) }) else { return nil }
        var result = [String]()
        var line = ""
        var previous: CGRect?
        var previousWasWhitespace = true
        func finish() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            line = ""
            previous = nil
            previousWasWhitespace = true
        }
        for (index, scalar) in text.unicodeScalars.enumerated() {
            if CharacterSet.newlines.contains(scalar) { finish(); continue }
            let values = rectangles[index]
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] >= 0, values[3] >= 0 else { return nil }
            if !CharacterSet.whitespaces.contains(scalar) {
                let box = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                if let previous, !previousWasWhitespace {
                    let overlap = min(previous.maxY, box.maxY) - max(previous.minY, box.minY)
                    let gap = box.minX - previous.maxX
                    if overlap > min(previous.height, box.height) * 0.5,
                       gap > max(4, max(previous.height, box.height) * 0.6) {
                        line += " "
                    }
                }
                previous = box
            }
            previousWasWhitespace = CharacterSet.whitespaces.contains(scalar)
            line.unicodeScalars.append(scalar)
        }
        finish()
        return result
    }
}
#endif
