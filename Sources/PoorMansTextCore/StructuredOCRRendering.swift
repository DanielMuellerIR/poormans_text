import Foundation

struct StructuredOCRPage: Sendable {
    struct Block: Sendable {
        let text: String
        let markdown: String
        let bounds: CGRect
    }
    let blocks: [Block]
    let flattenedSpans: Bool
    var markdown: String { blocks.map(\.markdown).joined(separator: "\n\n") }
}

enum StructuredOCRRendering {
    enum Failure: Error { case insufficientStructure, invalidStructure, outputTooLarge }
    private static let maximumBytes = 8_000_000

    static func render(_ recognition: StructuredDocumentRecognition) throws -> StructuredOCRPage {
        var blocks: [StructuredOCRPage.Block] = []
        var flattenedSpans = false
        var bytes = 0
        var documentBounds: [CGRect] = []
        guard !recognition.documents.isEmpty else { throw Failure.insufficientStructure }
        for document in recognition.documents {
            try ConversionExecution.check()
            guard valid(document.text.bounds), !documentBounds.contains(where: { $0.intersects(document.text.bounds) }) else {
                throw Failure.invalidStructure
            }
            documentBounds.append(document.text.bounds)
            let paragraphs = document.paragraphs
            guard !paragraphs.isEmpty, !document.text.text.isEmpty,
                  inventory(paragraphs.map(\.text)) == inventory([document.text.text]) else {
                throw Failure.insufficientStructure
            }
            guard paragraphs.allSatisfy({ valid($0.bounds) }) else { throw Failure.invalidStructure }
            var replacements: [Int: StructuredOCRPage.Block] = [:]
            var claimed = Set<Int>()
            func replace(_ block: StructuredOCRPage.Block) throws {
                guard valid(block.bounds) else { throw Failure.invalidStructure }
                let covered = paragraphs.indices.filter { containsCenter(block.bounds, paragraphs[$0].bounds) }
                guard let first = covered.first, claimed.isDisjoint(with: covered),
                      inventory(covered.map { paragraphs[$0].text }) == inventory([block.text]) else {
                    throw Failure.insufficientStructure
                }
                claimed.formUnion(covered)
                replacements[first] = block
            }
            for table in document.tables {
                let rendered = try renderTable(table)
                flattenedSpans = flattenedSpans || rendered.spans
                try replace(.init(text: table.cells.map { $0.text.text }.joined(separator: "\n"),
                    markdown: rendered.markdown, bounds: table.bounds))
            }
            for list in document.lists {
                guard !list.items.isEmpty else { throw Failure.invalidStructure }
                let text = list.items.map { $0.marker + $0.text.text }.joined(separator: "\n")
                let markdown = list.items.map { item in
                    func entry(_ prefix: String) -> String {
                        prefix + MarkdownEscaping.literalBlock(item.text.text)
                            .replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: prefix.count))
                    }
                    switch item.markerKind {
                    case .bullet, .hyphen: return entry("- ")
                    case .decimal:
                        let marker = item.marker.trimmingCharacters(in: .whitespacesAndNewlines)
                        let number = marker.dropLast()
                        if marker.last == ".", !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), number.count <= 9 {
                            return entry(marker + " ")
                        }
                        fallthrough
                    default: return MarkdownEscaping.literalBlock(item.marker + item.text.text)
                    }
                }.joined(separator: "\n")
                try replace(.init(text: text, markdown: markdown, bounds: list.bounds))
            }
            for index in paragraphs.indices {
                try ConversionExecution.check()
                let block: StructuredOCRPage.Block
                if let replacement = replacements[index] { block = replacement }
                else if claimed.contains(index) { continue }
                else {
                    let paragraph = paragraphs[index]
                    block = .init(text: paragraph.text, markdown: MarkdownEscaping.literalBlock(paragraph.text), bounds: paragraph.bounds)
                }
                guard block.markdown.utf8.count <= maximumBytes - bytes else { throw Failure.outputTooLarge }
                bytes += block.markdown.utf8.count
                blocks.append(block)
            }
        }
        guard !blocks.isEmpty else { throw Failure.insufficientStructure }
        return .init(blocks: blocks, flattenedSpans: flattenedSpans)
    }

    private static func renderTable(_ table: StructuredDocumentRecognition.Table) throws -> (markdown: String, spans: Bool) {
        guard !table.cells.isEmpty, table.cells.allSatisfy({
            $0.rows.lowerBound >= 0 && $0.columns.lowerBound >= 0 && $0.rows.upperBound < 1_024 && $0.columns.upperBound < 1_024
        }) else { throw Failure.invalidStructure }
        let rows = (table.cells.map { $0.rows.upperBound }.max() ?? -1) + 1
        let columns = (table.cells.map { $0.columns.upperBound }.max() ?? -1) + 1
        guard rows > 0, columns > 0, columns <= 256, rows <= 4_096 / columns else { throw Failure.outputTooLarge }
        var grid = Array(repeating: Array(repeating: "", count: columns), count: rows)
        var occupied = Set<Int>()
        var spans = false
        for cell in table.cells {
            try ConversionExecution.check()
            guard cell.rows.lowerBound >= 0, cell.columns.lowerBound >= 0 else { throw Failure.invalidStructure }
            for row in cell.rows {
                for column in cell.columns {
                    guard occupied.insert(row * columns + column).inserted else { throw Failure.invalidStructure }
                }
            }
            spans = spans || cell.rows.count > 1 || cell.columns.count > 1
            grid[cell.rows.lowerBound][cell.columns.lowerBound] = MarkdownEscaping.inlineLiteral(cell.text.text)
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        // Vision liefert keine verlässliche Kopfzeilen-Semantik. Ein neutraler
        // leerer Kopf erhält deshalb auch die erste Datenzeile unverändert.
        let header = row(Array(repeating: "", count: columns))
        let separator = row(Array(repeating: "---", count: columns))
        return ([header, separator].joined(separator: "\n") + "\n" + grid.map(row).joined(separator: "\n"), spans)
    }

    static func inventory(_ strings: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for string in strings {
            for token in string.split(whereSeparator: \.isWhitespace) {
                result[String(token), default: 0] += 1
            }
        }
        return result
    }

    private static func containsCenter(_ container: CGRect, _ content: CGRect) -> Bool {
        container.insetBy(dx: -0.002, dy: -0.002).contains(CGPoint(x: content.midX, y: content.midY))
    }

    private static func valid(_ bounds: CGRect) -> Bool {
        bounds.minX.isFinite && bounds.minY.isFinite && bounds.width.isFinite && bounds.height.isFinite &&
            bounds.width > 0 && bounds.height > 0 && bounds.minX >= -0.01 && bounds.minY >= -0.01 &&
            bounds.maxX <= 1.01 && bounds.maxY <= 1.01
    }
}
