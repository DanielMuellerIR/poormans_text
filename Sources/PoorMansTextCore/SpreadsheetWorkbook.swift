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

enum SpreadsheetMarkdownRenderer {
    static func render(
        _ workbook: SpreadsheetWorkbook,
        sourceURL: URL,
        style: SpreadsheetRendering
    ) -> String {
        var sections = ["# \(sourceURL.deletingPathExtension().lastPathComponent)"]
        for sheet in workbook.sheets {
            sections.append("## Sheet: \(headingText(sheet.name))")
            guard !sheet.rows.isEmpty else {
                sections.append("_Empty sheet._")
                continue
            }
            switch style {
            case .markdownTable:
                sections.append(markdownTable(sheet.rows))
            case .tabSeparated:
                sections.append(tabSeparatedBlock(sheet.rows))
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func markdownTable(_ rows: [[SpreadsheetCell]]) -> String {
        let columnCount = max(1, rows.map(\.count).max() ?? 0)
        let padded = rows.map { row in
            row + Array(repeating: .empty, count: columnCount - row.count)
        }
        let header = tableRow(padded[0])
        let separator = "| " + Array(repeating: "---", count: columnCount)
            .joined(separator: " | ") + " |"
        let body = padded.dropFirst().map(tableRow)
        return ([header, separator] + body).joined(separator: "\n")
    }

    private static func tableRow(_ row: [SpreadsheetCell]) -> String {
        "| " + row.map { markdownCell($0.displayText) }.joined(separator: " | ") + " |"
    }

    private static func markdownCell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func tabSeparatedBlock(_ rows: [[SpreadsheetCell]]) -> String {
        let columnCount = max(1, rows.map(\.count).max() ?? 0)
        let lines = rows.map { row in
            let padded = row + Array(repeating: .empty, count: columnCount - row.count)
            return padded.map { escapedTSVCell($0.displayText) }.joined(separator: "\t")
        }
        let content = lines.joined(separator: "\n")
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: content) + 1))
        return "\(fence)tsv\n\(content)\n\(fence)"
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
