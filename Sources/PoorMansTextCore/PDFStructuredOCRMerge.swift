import Foundation

enum PDFStructuredOCRMerge {
    enum Failure: LocalizedError {
        case comparisonLimit, digitalGeometry, ambiguousOverlap
        var errorDescription: String? {
            "Structured OCR cannot safely merge digital PDF text with additional OCR text within its geometry limits. No result was published. Choose standard OCR or turn PDF OCR off."
        }
    }
    private static let maximumComparisons = 1_000_000
    static let conflictWarning = ConversionWarning(code: "pdf.ocrOriginalRetained",
        message: "OCR conflicts with digital PDF text at the same position. The digital original was retained; conflicting OCR text was omitted.")

    static func merge(_ page: StructuredOCRPage, original: [PDFTextLine], bounds: CGRect) throws -> String? {
        try ConversionExecution.check()
        guard !original.isEmpty else { return page.markdown }
        guard page.blocks.count <= maximumComparisons / original.count,
              original.allSatisfy({ valid($0.bounds) && $0.bounds != bounds }) else { return nil }
        var covered = Set<Int>()
        var blocks: [(markdown: String, bounds: CGRect)] = []
        for block in page.blocks {
            try ConversionExecution.check()
            let rectangle = rectangle(block.bounds, in: bounds)
            let matches = original.indices.filter { original[$0].bounds.intersects(rectangle) }
            if !matches.isEmpty {
                guard covered.isDisjoint(with: matches),
                      key(matches.map { original[$0].text }.joined(separator: "\n")) == key(block.text) else { return nil }
                covered.formUnion(matches)
            }
            blocks.append((block.markdown, rectangle))
        }
        // Die von Vision belegte Spaltenreihenfolge bleibt bestehen. Digitaler
        // Zusatztext wird vor dem ersten darunter liegenden Block eingefügt.
        var insertions: [Int: [String]] = [:]
        for index in original.indices where !covered.contains(index) {
            try ConversionExecution.check()
            let source = original[index]
            let position = blocks.firstIndex { $0.bounds.midY < source.bounds.midY } ?? blocks.endIndex
            insertions[position, default: []].append(MarkdownEscaping.literalBlock(source.text))
        }
        var rendered: [String] = []
        for index in blocks.indices {
            rendered += insertions[index] ?? []
            rendered.append(blocks[index].markdown)
        }
        rendered += insertions[blocks.endIndex] ?? []
        return rendered.joined(separator: "\n\n")
    }

    static func supplementaryLines(_ recognized: VisionTextRecognition, original: [PDFTextLine], bounds: CGRect)
        throws -> (lines: [PDFTextLine], conflict: Bool) {
        try ConversionExecution.check()
        var lines: [PDFTextLine] = []
        var conflict = false
        if recognized.lines.isEmpty { return ([], false) }
        guard original.isEmpty || recognized.lines.count <= maximumComparisons / original.count else { throw Failure.comparisonLimit }
        if original.contains(where: { !valid($0.bounds) || $0.bounds == bounds }) {
            if StructuredOCRRendering.inventory(original.map(\.text)) == StructuredOCRRendering.inventory(recognized.lines.map(\.recognized)) {
                return ([], false)
            }
            throw Failure.digitalGeometry
        }
        for line in recognized.lines {
            try ConversionExecution.check()
            let rectangle = rectangle(line.bounds, in: bounds)
            let matches = original.filter { $0.bounds.intersects(rectangle) }
            if !matches.isEmpty {
                if !matches.contains(where: { key($0.text) == key(line.recognized) }) {
                    let originalRegion = matches.reduce(CGRect.null) { $0.union($1.bounds) }
                    let tolerance = max(2, rectangle.height * 0.5)
                    guard originalRegion.insetBy(dx: -tolerance, dy: -tolerance).contains(rectangle) else { throw Failure.ambiguousOverlap }
                    conflict = true
                }
                continue
            }
            lines.append(PDFTextLine(text: line.text, bounds: rectangle))
        }
        return (lines, conflict)
    }

    private static func key(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func rectangle(_ normalized: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + normalized.minX * bounds.width, y: bounds.minY + normalized.minY * bounds.height,
               width: normalized.width * bounds.width, height: normalized.height * bounds.height)
    }
    private static func valid(_ bounds: CGRect) -> Bool {
        bounds.minX.isFinite && bounds.minY.isFinite && bounds.width.isFinite && bounds.height.isFinite && !bounds.isEmpty && !bounds.isNull
    }
}
