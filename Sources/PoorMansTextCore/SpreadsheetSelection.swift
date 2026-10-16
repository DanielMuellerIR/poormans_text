import Foundation

public enum SpreadsheetSheetVisibility: String, Codable, Hashable, Sendable {
    case visible, hidden, veryHidden, unknown
}

public struct SpreadsheetSheetSummary: Codable, Hashable, Sendable {
    public let index: Int
    public let name: String
    public let visibility: SpreadsheetSheetVisibility
    public let isReadable: Bool
}

public struct SpreadsheetContentSummary: Codable, Sendable {
    public let sourceIdentity: ConversionSourceIdentity
    public let sheets: [SpreadsheetSheetSummary]
}

public enum SpreadsheetSheetSelection: Codable, Hashable, Sendable {
    case all
    case visible
    case indices(IndexSelection)
    case names([String])
}

/// Einsbasierter, geschlossener A1-Bereich innerhalb der unterstützten Grenzen.
public struct SpreadsheetCellRange: Codable, Hashable, Sendable, CustomStringConvertible {
    public let firstRow: Int
    public let lastRow: Int
    public let firstColumn: Int
    public let lastColumn: Int

    public init(_ expression: String) throws {
        guard expression.utf8.count <= 128 else { throw SpreadsheetSelectionError("a cell range exceeds 128 bytes") }
        let parts = expression.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = Self.address(String(parts[0])),
              let last = Self.address(String(parts.last!)), first.row <= last.row, first.column <= last.column else {
            throw SpreadsheetSelectionError("a cell range must be an ascending A1 address or rectangle, for example B2:D8")
        }
        self.init(firstRow: first.row, lastRow: last.row, firstColumn: first.column, lastColumn: last.column)
    }

    init(firstRow: Int, lastRow: Int, firstColumn: Int, lastColumn: Int) {
        self.firstRow = firstRow; self.lastRow = lastRow
        self.firstColumn = firstColumn; self.lastColumn = lastColumn
    }

    static func address(_ text: String) -> (row: Int, column: Int)? {
        guard text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        let bytes = Array(text.uppercased().utf8)
        var index = 0, column = 0
        while index < bytes.count, (65...90).contains(bytes[index]) {
            guard index < 3 else { return nil }
            column = column * 26 + Int(bytes[index] - 64); index += 1
        }
        guard index > 0, index < bytes.count, bytes[index] != 48,
              bytes[index...].allSatisfy({ (48...57).contains($0) }),
              let row = Int(String(decoding: bytes[index...], as: UTF8.self)),
              (1...SpreadsheetLimits.maximumRows).contains(row), (1...SpreadsheetLimits.maximumColumns).contains(column) else { return nil }
        return (row, column)
    }

    static func columnName(_ value: Int) -> String {
        var value = value, name = ""
        while value > 0 { value -= 1; name = String(UnicodeScalar(65 + value % 26)!) + name; value /= 26 }
        return name
    }

    public var description: String {
        let first = Self.columnName(firstColumn) + String(firstRow)
        let last = Self.columnName(lastColumn) + String(lastRow)
        return first == last ? first : first + ":" + last
    }

    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
}

public struct SpreadsheetSelection: Codable, Hashable, Sendable {
    public let sheets: SpreadsheetSheetSelection
    public let ranges: [SpreadsheetCellRange]

    public init(sheets: SpreadsheetSheetSelection = .all, ranges: [SpreadsheetCellRange] = []) throws {
        if case .names(let names) = sheets {
            guard !names.isEmpty, names.count <= SpreadsheetLimits.maximumSheets,
                  names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }) else {
                throw SpreadsheetSelectionError("sheet names must be nonempty and limited to 256 names of 1024 bytes each")
            }
        }
        guard ranges.count <= 64 else { throw SpreadsheetSelectionError("at most 64 cell ranges may be selected") }
        if case .names(let names) = sheets { self.sheets = .names(Array(Set(names)).sorted()) }
        else { self.sheets = sheets }
        self.ranges = Array(Set(ranges)).sorted { ($0.firstRow, $0.firstColumn, $0.lastRow, $0.lastColumn) < ($1.firstRow, $1.firstColumn, $1.lastRow, $1.lastColumn) }
    }

    enum CodingKeys: String, CodingKey { case sheets, ranges }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sheets: c.decode(SpreadsheetSheetSelection.self, forKey: .sheets), ranges: c.decode([SpreadsheetCellRange].self, forKey: .ranges))
    }

    func selectedIndices(in summaries: [SpreadsheetSheetSummary]) throws -> Set<Int> {
        let chosen: Set<Int>
        switch sheets {
        case .all: chosen = Set(summaries.filter(\.isReadable).map(\.index))
        case .visible:
            guard !summaries.contains(where: { $0.isReadable && $0.visibility == .unknown }) else {
                throw SpreadsheetSelectionError("a sheet has unknown visibility; select all sheets, names or indices explicitly")
            }
            chosen = Set(summaries.filter { $0.isReadable && $0.visibility == .visible }.map(\.index))
        case .indices(let indices):
            chosen = Set(try indices.zeroBasedIndices(itemCount: summaries.count).map { $0 + 1 })
            guard summaries.filter({ chosen.contains($0.index) }).allSatisfy(\.isReadable) else {
                throw SpreadsheetSelectionError("the selection includes an unsupported chart, dialog or macro sheet")
            }
        case .names(let names):
            var indices = Set<Int>()
            for name in Set(names) {
                let matches = summaries.filter { $0.name == name }
                guard matches.count == 1, let match = matches.first, match.isReadable else {
                    throw SpreadsheetSelectionError("sheet name is missing, ambiguous or unsupported: \(name); use source indices for duplicate names")
                }
                indices.insert(match.index)
            }
            chosen = indices
        }
        guard !chosen.isEmpty else { throw SpreadsheetSelectionError("the sheet selection is empty") }
        return chosen
    }

    /// Zerlegt die Vereinigung in disjunkte Streifen. Große Lücken zwischen
    /// Bereichen werden nicht zu einer gemeinsamen rechteckigen Tabelle gefüllt.
    func disjointRanges(rowCount: Int, columnCount: Int) throws -> [SpreadsheetCellRange] {
        let clipped = ranges.compactMap { range -> SpreadsheetCellRange? in
            guard range.firstRow <= rowCount, range.firstColumn <= columnCount else { return nil }
            return .init(firstRow: range.firstRow, lastRow: min(range.lastRow, rowCount), firstColumn: range.firstColumn, lastColumn: min(range.lastColumn, columnCount))
        }
        let boundaries = Set(clipped.flatMap { [$0.firstRow, $0.lastRow + 1] }).sorted()
        var result = [SpreadsheetCellRange]()
        for (firstRow, nextRow) in zip(boundaries, boundaries.dropFirst()) {
            try ConversionExecution.check()
            let intervals = clipped.filter { $0.firstRow <= firstRow && $0.lastRow >= firstRow }
                .map { $0.firstColumn...$0.lastColumn }.sorted { $0.lowerBound < $1.lowerBound }
            var merged = [ClosedRange<Int>]()
            for interval in intervals {
                if let previous = merged.last, interval.lowerBound <= previous.upperBound + 1 {
                    merged[merged.count - 1] = previous.lowerBound...max(previous.upperBound, interval.upperBound)
                } else { merged.append(interval) }
            }
            for interval in merged {
                result.append(.init(firstRow: firstRow, lastRow: nextRow - 1, firstColumn: interval.lowerBound, lastColumn: interval.upperBound))
            }
            guard result.count <= 4_096 else { throw SpreadsheetSelectionError("the union of selected ranges exceeds 4096 output regions") }
        }
        return result
    }
}

struct SpreadsheetSelectionError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

extension SpreadsheetWorkbook {
    var summaries: [SpreadsheetSheetSummary] {
        if !sheetSummaries.isEmpty { return sheetSummaries }
        return sheets.enumerated().map { .init(index: $0.element.sourceIndex ?? $0.offset + 1, name: $0.element.name, visibility: $0.element.visibility, isReadable: true) }
    }

    func selecting(_ selection: SpreadsheetSelection) throws -> SpreadsheetWorkbook {
        let chosen = try selection.selectedIndices(in: summaries)
        var result = self
        result.sheets = []
        result.isSelection = true
        var remaining = SpreadsheetLimits.maximumCells
        for (offset, original) in sheets.enumerated() {
            try ConversionExecution.check()
            let index = original.sourceIndex ?? offset + 1
            guard chosen.contains(index) else { continue }
            var sheet = original
            sheet.sourceIndex = index
            sheet.selectionLabel = "Source sheet \(index)"
            if selection.ranges.isEmpty { result.sheets.append(sheet); continue }
            let columns = sheet.rows.reduce(0) { max($0, $1.count) }
            let regions = try selection.disjointRanges(rowCount: sheet.rows.count, columnCount: columns)
            if regions.isEmpty {
                sheet.rows = []
                sheet.selectionLabel = "Source sheet \(index) · Selected ranges contain no populated cells"
                result.sheets.append(sheet)
            }
            for range in regions {
                let width = range.lastColumn - range.firstColumn + 1
                let height = range.lastRow - range.firstRow + 1
                guard height <= remaining / width else { throw SpreadsheetSelectionError(SpreadsheetLimits.cellBudgetMessage) }
                remaining -= height * width
                var region = sheet
                region.originRow = range.firstRow - 1
                region.originColumn = range.firstColumn - 1
                region.selectionLabel = "Source sheet \(index) · Range \(range)"
                region.rows = []
                for rowIndex in (range.firstRow - 1)..<range.lastRow {
                    try ConversionExecution.check()
                    let row = sheet.rows[rowIndex]
                    region.rows.append(((range.firstColumn - 1)..<range.lastColumn).map { row.indices.contains($0) ? row[$0] : .empty })
                }
                result.sheets.append(region)
            }
        }
        try SpreadsheetLimits.validate(result)
        return result
    }
}
