import Foundation

enum SpreadsheetCellValue: Equatable, Sendable {
    case empty
    case string(String)
    case number(String)
    case boolean(Bool)
    case date(String)
}

struct SpreadsheetCell: Equatable, Sendable {
    let value: SpreadsheetCellValue
    let displayText: String
    let formula: String?

    static let empty = SpreadsheetCell(value: .empty, displayText: "", formula: nil)

    var isEmpty: Bool {
        displayText.isEmpty && formula == nil
    }
}

struct SpreadsheetSheet: Equatable, Sendable {
    let name: String
    var rows: [[SpreadsheetCell]]
}

struct SpreadsheetWorkbook: Equatable, Sendable {
    var sheets: [SpreadsheetSheet]
    var hasFlattenedMerges = false
    var hasFormulaWithoutResult = false
    var hasUnsupportedObjects = false
}

enum SpreadsheetLimits {
    /// Genug für große reale Tabellen, aber klein genug, damit wiederverwendete
    /// Zelltexte keine praktisch unbegrenzte Markdown-Ausgabe erzeugen können.
    static let maximumOutputBytes = 128 * 1_024 * 1_024
}

enum SpreadsheetMarkdownRenderer {
    static func render(
        _ workbook: SpreadsheetWorkbook,
        sourceURL: URL,
        style: SpreadsheetRendering,
        maximumOutputBytes: Int = SpreadsheetLimits.maximumOutputBytes
    ) throws -> String {
        var output = BoundedSpreadsheetOutput(maximumBytes: maximumOutputBytes)
        try output.append("# \(sourceURL.deletingPathExtension().lastPathComponent)")
        for sheet in workbook.sheets {
            try output.append("\n\n## Sheet: \(headingText(sheet.name))\n\n")
            guard !sheet.rows.isEmpty else {
                try output.append("_Empty sheet._")
                continue
            }
            switch style {
            case .markdownTable:
                try appendMarkdownTable(sheet.rows, to: &output)
            case .tabSeparated:
                try appendTabSeparatedBlock(sheet.rows, to: &output)
            }
        }
        try output.append("\n")
        return output.value
    }

    private static func appendMarkdownTable(
        _ rows: [[SpreadsheetCell]],
        to output: inout BoundedSpreadsheetOutput
    ) throws {
        let columnCount = max(1, rows.map(\.count).max() ?? 0)
        try appendTableRow(rows[0], columnCount: columnCount, to: &output)
        try output.append("\n| ")
        for column in 0..<columnCount {
            if column > 0 {
                try output.append(" | ")
            }
            try output.append("---")
        }
        try output.append(" |")
        for row in rows.dropFirst() {
            try output.append("\n")
            try appendTableRow(row, columnCount: columnCount, to: &output)
        }
    }

    private static func appendTableRow(
        _ row: [SpreadsheetCell],
        columnCount: Int,
        to output: inout BoundedSpreadsheetOutput
    ) throws {
        try output.append("| ")
        for column in 0..<columnCount {
            if column > 0 {
                try output.append(" | ")
            }
            if row.indices.contains(column) {
                try output.append(markdownCell(row[column].displayText))
            }
        }
        try output.append(" |")
    }

    private static func markdownCell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func appendTabSeparatedBlock(
        _ rows: [[SpreadsheetCell]],
        to output: inout BoundedSpreadsheetOutput
    ) throws {
        let columnCount = max(1, rows.map(\.count).max() ?? 0)
        let longestTicks = try longestBacktickRunWithinBudget(
            rows,
            columnCount: columnCount,
            budget: output.remainingBytes
        )
        let fence = String(repeating: "`", count: max(3, longestTicks + 1))
        try output.append("\(fence)tsv\n")
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 {
                try output.append("\n")
            }
            for column in 0..<columnCount {
                if column > 0 {
                    try output.append("\t")
                }
                if row.indices.contains(column) {
                    try output.append(escapedTSVCell(row[column].displayText))
                }
            }
        }
        try output.append("\n\(fence)")
    }

    private static func escapedTSVCell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func headingText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Längste Backtick-Folge aller Zellen — aber nur, solange die spätere
    /// Ausgabe überhaupt noch ins Budget passt.
    ///
    /// Der frühere Vorlauf las ALLE Zelltexte, bevor der erste begrenzte Append
    /// lief. Der ODS-Parser darf denselben Zelltext über Zeilen- und
    /// Spaltenwiederholungen bis zu eine Million Mal referenzieren; ein kleines,
    /// stark komprimiertes ODS erzwang damit Zeichenarbeit im Terabyte-Bereich
    /// für eine Ausgabe, die schon nach 128 MiB abgelehnt wird — das
    /// Ausgabelimit schützte diesen Vorlauf nicht (Review-Fund 2026-08-17).
    /// Derselbe Durchlauf zählt deshalb eine UNTERGRENZE der TSV-Bytes mit und
    /// bricht ab, sobald sie das Restbudget übersteigt. Untergrenze heißt: das
    /// Escaping vergrößert jeden Zelltext nur, die rohe UTF-8-Länge wird also
    /// nie überschätzt.
    private static func longestBacktickRunWithinBudget(
        _ rows: [[SpreadsheetCell]],
        columnCount: Int,
        budget: Int
    ) throws -> Int {
        var longest = 0
        // Wächst pro Zelle um höchstens die Länge dieser einen Zelle und wird
        // danach sofort geprüft — ein Überlauf ist damit ausgeschlossen.
        var lowerBoundBytes = 0
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 {
                lowerBoundBytes += 1                    // Zeilentrenner
            }
            lowerBoundBytes += max(0, columnCount - 1)  // Spaltentrenner
            guard lowerBoundBytes <= budget else {
                throw SpreadsheetRenderError(
                    "the spreadsheet output exceeds the supported size limit"
                )
            }
            for column in 0..<columnCount where row.indices.contains(column) {
                let text = row[column].displayText
                lowerBoundBytes += text.utf8.count
                guard lowerBoundBytes <= budget else {
                    throw SpreadsheetRenderError(
                        "the spreadsheet output exceeds the supported size limit"
                    )
                }
                longest = max(longest, longestBacktickRun(in: text))
            }
        }
        return longest
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

private struct BoundedSpreadsheetOutput {
    private(set) var value = ""
    private var byteCount = 0
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    /// Wie viele Bytes noch geschrieben werden dürfen. Ein Vorlauf, der Arbeit
    /// über die gesamte Eingabe leisten würde, braucht diese Zahl, um vorzeitig
    /// abzubrechen (siehe longestBacktickRunWithinBudget).
    var remainingBytes: Int { maximumBytes - byteCount }

    mutating func append(_ fragment: String) throws {
        let addedBytes = fragment.utf8.count
        guard addedBytes <= maximumBytes - byteCount else {
            throw SpreadsheetRenderError("the spreadsheet output exceeds the supported size limit")
        }
        value.append(fragment)
        byteCount += addedBytes
    }
}

private struct SpreadsheetRenderError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
