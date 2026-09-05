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
    /// Linkziel der Zelle. Der sichtbare Text bleibt getrennt, damit der
    /// Renderer ihn für die jeweilige Markdown-Darstellung sicher maskieren
    /// kann.
    let linkTarget: String?

    init(
        value: SpreadsheetCellValue,
        displayText: String,
        formula: String?,
        linkTarget: String? = nil
    ) {
        self.value = value
        self.displayText = displayText
        self.formula = formula
        self.linkTarget = linkTarget
    }

    static let empty = SpreadsheetCell(
        value: .empty,
        displayText: "",
        formula: nil,
        linkTarget: nil
    )

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
    var locatedDiagnostics: [ConversionWarning] = []
    var hasFlattenedMerges = false
    var hasFormulaWithoutResult = false
    var hasUnsupportedObjects = false
}

enum SpreadsheetLimits {
    /// Genug für große reale Tabellen, aber klein genug, damit wiederverwendete
    /// Zelltexte keine praktisch unbegrenzte Markdown-Ausgabe erzeugen können.
    static let maximumOutputBytes = 128 * 1_024 * 1_024
}

/// Entscheidet, ob ein Linkziel aus einer Quelldatei ins Ergebnis darf.
///
/// Poor Man's Text lädt selbst nichts nach, und ein Linkziel wird nie
/// geöffnet. Es steht danach aber als Markdown-Link im Ergebnis, und ein Klick
/// im Viewer des Nutzers führt aus, was in der Quelldatei stand — bei
/// `javascript:` und `data:` wäre das Code aus einer fremden Tabelle. Deshalb
/// kommt nur eine kurze Liste von Schemata durch.
enum SpreadsheetLinkTarget {
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto", "file"]

    /// Das übernehmbare Ziel — `nil`, wenn es verworfen wird. Der Aufrufer
    /// meldet ein verworfenes Ziel als sichtbaren Verlust.
    ///
    /// Ohne Schema bleibt ein Ziel erlaubt: Ein relativer Pfad neben der
    /// Arbeitsmappe und ein blattinternes `#`-Ziel tragen keines.
    static func accepted(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Steuerzeichen dienen in einem Linkziel keinem gültigen Zweck und
        // können ein Schema vor dieser Prüfung verstecken („java\nscript:").
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        guard let scheme = scheme(of: trimmed) else {
            return trimmed
        }
        return allowedSchemes.contains(scheme) ? trimmed : nil
    }

    /// Das Schema nach RFC 3986: ein Buchstabe, danach Buchstaben, Ziffern,
    /// `+`, `-` oder `.`, abgeschlossen mit `:`. Alles andere vor dem ersten
    /// Doppelpunkt heißt: Dieses Ziel trägt gar kein Schema.
    private static func scheme(of target: String) -> String? {
        var scheme = ""
        var index = target.startIndex
        while index < target.endIndex {
            let character = target[index]
            if character == ":" {
                guard !scheme.isEmpty else { return nil }
                return scheme.lowercased()
            }
            guard character.isASCII else { return nil }
            if scheme.isEmpty {
                guard character.isLetter else { return nil }
            } else {
                guard character.isLetter || character.isNumber
                        || character == "+" || character == "-" || character == "." else {
                    return nil
                }
            }
            scheme.append(character)
            index = target.index(after: index)
        }
        return nil
    }
}

enum SpreadsheetMarkdownRenderer {
    static func render(
        _ workbook: SpreadsheetWorkbook,
        sourceURL: URL,
        style: SpreadsheetRendering,
        maximumOutputBytes: Int = SpreadsheetLimits.maximumOutputBytes
    ) throws -> String {
        var output = BoundedSpreadsheetOutput(maximumBytes: maximumOutputBytes)
        try output.append(
            "# \(MarkdownEscaping.heading(sourceURL.deletingPathExtension().lastPathComponent))"
        )
        for (index, sheet) in workbook.sheets.enumerated() {
            try ConversionExecution.report(unit: .sheet, completed: index, total: workbook.sheets.count)
            try output.append("\n\n## Sheet: \(MarkdownEscaping.heading(sheet.name))\n\n")
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
            try ConversionExecution.check()
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
                try output.append(markdownCell(row[column]))
            }
        }
        try output.append(" |")
    }

    private static func markdownCell(_ cell: SpreadsheetCell) -> String {
        guard let target = cell.linkTarget, !target.isEmpty else {
            return escapedMarkdownText(cell.displayText)
        }
        return "[\(escapedMarkdownLinkText(cell.displayText))](\(escapedMarkdownLinkTarget(target)))"
    }

    private static func escapedMarkdownText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map(MarkdownEscaping.inlineLiteral)
            .joined(separator: "<br>")
    }

    /// Ein Linktext braucht zusätzlich maskierte Klammern. Ohne sie könnte
    /// Text aus der Quelldatei den erzeugten Link schließen oder eine neue
    /// Tabellenspalte beginnen.
    private static func escapedMarkdownLinkText(_ text: String) -> String {
        escapedMarkdownText(text)
    }

    /// Markdown akzeptiert in einer Linkadresse weder Leer- noch Steuerzeichen
    /// oder unmaskierte Klammern zuverlässig. Die Ersetzung bewahrt den Wert
    /// als URL und verhindert zugleich, dass ein Quellwert die Linksyntax
    /// verlassen kann.
    private static func escapedMarkdownLinkTarget(_ target: String) -> String {
        var escaped = ""
        for scalar in target.unicodeScalars {
            switch scalar.value {
            case 0x00...0x20, 0x7F, 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5C, 0x5D, 0x7C:
                escaped += scalar.utf8.map { String(format: "%%%02X", $0) }.joined()
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
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
            try ConversionExecution.check()
            if rowIndex > 0 {
                try output.append("\n")
            }
            for column in 0..<columnCount {
                if column > 0 {
                    try output.append("\t")
                }
                if row.indices.contains(column) {
                    try output.append(tsvCell(row[column]))
                }
            }
        }
        try output.append("\n\(fence)")
    }

    private static func tsvCell(_ cell: SpreadsheetCell) -> String {
        let text: String
        if let target = cell.linkTarget, !target.isEmpty {
            // Ein TSV-Codeblock kann keinen anklickbaren Markdown-Link
            // enthalten. Seine reversible Zellrepräsentation bewahrt aber
            // Linktext und -ziel als Markdown-Quelltext statt das Ziel still
            // zu verwerfen.
            text = "[\(escapedMarkdownLinkText(cell.displayText))](\(escapedMarkdownLinkTarget(target)))"
        } else {
            text = cell.displayText
        }
        return escapedTSVText(text)
    }

    private static func escapedTSVText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
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
            try ConversionExecution.check()
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
