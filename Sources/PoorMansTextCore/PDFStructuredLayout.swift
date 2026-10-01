import Foundation
import PDFKit

/// Struktur wird nur vom Renderer erzeugt; Quellzeichen bleiben maskiert.
enum PDFStructuredLayout {
    struct Page {
        let markdown: String
        let ambiguous: Bool
    }

    static func bodyFont(in pages: [[PDFTextLine]]) -> CGFloat? {
        var weights: [CGFloat: Int] = [:]
        for line in pages.flatMap({ $0 }) {
            if let size = line.fontSize, !line.isBold {
                weights[size, default: 0] += line.text.filter { !$0.isWhitespace }.count
            }
        }
        return weights.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }?.key
    }

    static func render(_ lines: [PDFTextLine], page: PDFPage, bodyFont: CGFloat?, headingSizes: [CGFloat], hardHyphens: Bool) -> Page {
        if lines.count == 1, lines[0].bounds == page.bounds(for: .mediaBox) {
            return Page(markdown: MarkdownEscaping.literalBlock(ExtractedText.normalized(PDFTextLayout.text(lines, hardHyphens: hardHyphens))), ambiguous: false)
        }
        let heights = lines.filter { !$0.text.contains("\n") }.map(\.bounds.height).filter { $0 > 0 }.sorted()
        let grids = heights.isEmpty ? [] : PDFTableGeometry.grids(on: page, textHeight: heights[heights.count / 2])
        var consumed = Set<Int>()
        var blocks: [(line: PDFTextLine, table: String?)] = []
        for grid in grids {
            let indices = lines.indices.filter { grid.bounds.contains(CGPoint(x: lines[$0].bounds.midX, y: lines[$0].bounds.midY)) }
            guard !indices.isEmpty, consumed.isDisjoint(with: indices) else { continue }
            var cells = Array(repeating: Array(repeating: [PDFTextLine](), count: grid.columns.count - 1), count: grid.rows.count - 1)
            var safe = true
            for index in indices {
                let line = lines[index]
                guard let row = (0..<grid.rows.count-1).first(where: { line.bounds.midY < grid.rows[$0] && line.bounds.midY > grid.rows[$0+1] }),
                      let column = (0..<grid.columns.count-1).first(where: { line.bounds.midX > grid.columns[$0] && line.bounds.midX < grid.columns[$0+1] }),
                      line.bounds.minX >= grid.columns[column], line.bounds.maxX <= grid.columns[column+1],
                      line.bounds.minY >= grid.rows[row+1], line.bounds.maxY <= grid.rows[row] else { safe = false; break }
                cells[row][column].append(line)
            }
            guard safe, cells.count >= 2, cells.allSatisfy({ $0.contains { !$0.isEmpty } }) else { continue }
            let strings = cells.map { row in row.map { cell in
                cell.sorted { $0.bounds.midY > $1.bounds.midY }.map { MarkdownEscaping.inlineLiteral(ExtractedText.normalized($0.text)) }.joined(separator: "<br>")
            } }
            func numeric(_ cell: [PDFTextLine]) -> Bool {
                let value = cell.map(\.text).joined().filter { !$0.isWhitespace }
                return !value.isEmpty && value.allSatisfy(\.isNumber)
            }
            let numericHeader = cells[0].indices.contains { column in
                !cells[0][column].isEmpty && !numeric(cells[0][column]) && cells.dropFirst().allSatisfy { numeric($0[column]) }
            }
            let hasHeader = numericHeader || cells[0].allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isBold) }
            func row(_ values: [String]) -> String { "| " + values.joined(separator: " | ") + " |" }
            let header = hasHeader ? strings[0] : Array(repeating: "", count: grid.columns.count - 1)
            let table = ([row(header), row(Array(repeating: "---", count: header.count))] + (hasHeader ? Array(strings.dropFirst()) : strings).map(row)).joined(separator: "\n")
            blocks.append((PDFTextLine(text: "", bounds: grid.bounds), table))
            consumed.formUnion(indices)
        }
        for index in lines.indices where !consumed.contains(index) { blocks.append((lines[index], nil)) }
        let markers = blocks.enumerated().map { PDFTextLine(text: $0.element.line.text, bounds: $0.element.line.bounds, sourceLine: $0.offset) }
        let ambiguous = PDFTextLayout.hasAmbiguousColumns(markers, pageBounds: page.bounds(for: .mediaBox), evidence: blocks.map(\.line))
        var ordered = ambiguous ? PDFTextLayout.rowOrdered(markers) : PDFTextLayout.ordered(markers, pageBounds: page.bounds(for: .mediaBox))
        if !ambiguous {
            // Eine allein stehende Seitenzahl gehört hinter beide Spalten.
            // Die Randzone entspricht der vorhandenen Kopf-/Fußzeilenoption.
            let box = page.bounds(for: .mediaBox)
            let footers = ordered.filter { marker in
                let value = marker.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && value.allSatisfy(\.isNumber) && marker.bounds.midY < box.minY + box.height * 0.10
            }
            let footerIDs = Set(footers.map(\.sourceLine))
            ordered = ordered.filter { !footerIDs.contains($0.sourceLine) } + footers
        }
        var output = [String]()
        var prose = [PDFTextLine]()
        func flush() {
            if !prose.isEmpty { output.append(MarkdownEscaping.literalBlock(ExtractedText.normalized(PDFTextLayout.text(prose, hardHyphens: hardHyphens)))) }
            prose = []
        }
        for marker in ordered {
            let block = blocks[marker.sourceLine]
            if let table = block.table { flush(); output.append(table) }
            else if let size = block.line.fontSize, let bodyFont, size > bodyFont,
                    !block.line.text.contains("\n"), block.line.text.contains(where: { $0.isLetter }), let level = headingSizes.firstIndex(of: size) {
                flush()
                output.append(String(repeating: "#", count: min(6, level + 3)) + " " + MarkdownEscaping.heading(ExtractedText.normalized(block.line.text)))
            } else { prose.append(block.line) }
        }
        flush()
        if ambiguous { output.insert("_PDF layout uncertain: aligned text may be a table or parallel columns; row order was retained._", at: 0) }
        return Page(markdown: output.joined(separator: "\n\n"), ambiguous: ambiguous)
    }
}
