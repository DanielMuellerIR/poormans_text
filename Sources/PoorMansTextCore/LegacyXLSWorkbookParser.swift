import Foundation

enum LegacyXLSWorkbookParser {
    static func parse(_ data: Data) throws -> SpreadsheetWorkbook {
        let compound = try CompoundDocument(data: data)
        guard let workbookStream = try compound.stream(named: "Workbook")
            ?? compound.stream(named: "Book") else {
            throw ParserError("the OLE compound document contains no Excel workbook stream")
        }
        var workbook = try BIFFParser.parse(workbookStream)
        workbook.hasUnsupportedObjects = workbook.hasUnsupportedObjects
            || compound.entryNames.contains {
                $0.caseInsensitiveCompare("_VBA_PROJECT_CUR") == .orderedSame
                    || $0.localizedCaseInsensitiveContains("VBA")
                    || $0.localizedCaseInsensitiveContains("ObjectPool")
            }
        return workbook
    }

    static func looksLikeXLS(_ data: Data) -> Bool {
        guard let compound = try? CompoundDocument(data: data) else {
            return false
        }
        let candidate: Data?
        do {
            candidate = try compound.stream(named: "Workbook")
                ?? compound.stream(named: "Book")
        } catch {
            return false
        }
        guard let stream = candidate, stream.count >= 8 else { return false }
        return stream.legacyUInt16(at: 0) == 0x0809
            && stream.legacyUInt16(at: 6) == 0x0005
    }

    private struct CompoundDocument {
        let data: Data
        let sectorSize: Int
        let miniSectorSize: Int
        let miniStreamCutoff: Int
        let fat: [UInt32]
        let miniFAT: [UInt32]
        let miniStream: Data
        private let entries: [DirectoryEntry]

        var entryNames: [String] { entries.map(\.name) }

        init(data: Data) throws {
            guard data.count >= 512,
                  Array(data.prefix(8)) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1],
                  data.legacyUInt16(at: 28) == 0xFFFE else {
                throw ParserError("the OLE compound-document header is invalid")
            }
            self.data = data
            let majorVersion = data.legacyUInt16(at: 26)
            let sectorShift = Int(data.legacyUInt16(at: 30))
            let miniSectorShift = Int(data.legacyUInt16(at: 32))
            guard (majorVersion == 3 && sectorShift == 9)
                    || (majorVersion == 4 && sectorShift == 12),
                  miniSectorShift == 6 else {
                throw ParserError("the OLE sector layout is unsupported")
            }
            sectorSize = 1 << sectorShift
            miniSectorSize = 1 << miniSectorShift
            miniStreamCutoff = Int(data.legacyUInt32(at: 56))
            guard data.count >= sectorSize,
                  (data.count - sectorSize) % sectorSize == 0,
                  miniStreamCutoff <= Limits.maximumStreamSize else {
                throw ParserError("the OLE file size or mini-stream cutoff is invalid")
            }

            let sectorCount = (data.count - sectorSize) / sectorSize
            let fatSectorCount = Int(data.legacyUInt32(at: 44))
            var fatSectorIDs = [UInt32]()
            for index in 0..<109 {
                let id = data.legacyUInt32(at: 76 + index * 4)
                if id != Constants.freeSector { fatSectorIDs.append(id) }
            }
            var difatSector = data.legacyUInt32(at: 68)
            let difatCount = Int(data.legacyUInt32(at: 72))
            var seenDIFAT = Set<UInt32>()
            for _ in 0..<difatCount {
                guard difatSector < UInt32(sectorCount), seenDIFAT.insert(difatSector).inserted else {
                    throw ParserError("the OLE DIFAT chain is invalid")
                }
                let sector = try Self.sector(difatSector, in: data, sectorSize: sectorSize)
                for index in 0..<(sectorSize / 4 - 1) {
                    let id = sector.legacyUInt32(at: index * 4)
                    if id != Constants.freeSector { fatSectorIDs.append(id) }
                }
                difatSector = sector.legacyUInt32(at: sectorSize - 4)
            }
            guard fatSectorIDs.count >= fatSectorCount else {
                throw ParserError("the OLE FAT sector list is incomplete")
            }
            fatSectorIDs = Array(fatSectorIDs.prefix(fatSectorCount))
            var parsedFAT = [UInt32]()
            for id in fatSectorIDs {
                guard id < UInt32(sectorCount) else {
                    throw ParserError("an OLE FAT sector lies outside the file")
                }
                let sector = try Self.sector(id, in: data, sectorSize: sectorSize)
                for offset in stride(from: 0, to: sector.count, by: 4) {
                    parsedFAT.append(sector.legacyUInt32(at: offset))
                }
            }
            fat = parsedFAT

            let directoryStart = data.legacyUInt32(at: 48)
            let directoryData = try Self.standardStream(
                start: directoryStart,
                size: nil,
                data: data,
                sectorSize: sectorSize,
                fat: parsedFAT
            )
            guard directoryData.count >= 128 else {
                throw ParserError("the OLE directory stream is truncated")
            }
            var parsedEntries = [DirectoryEntry]()
            for offset in stride(from: 0, through: max(0, directoryData.count - 128), by: 128) {
                let nameByteCount = Int(directoryData.legacyUInt16(at: offset + 64))
                guard nameByteCount == 0
                        || nameByteCount >= 2 && nameByteCount <= 64 && nameByteCount % 2 == 0 else {
                    throw ParserError("an OLE directory name is invalid")
                }
                guard nameByteCount > 0 else { continue }
                var units = [UInt16]()
                for nameOffset in stride(from: offset, to: offset + nameByteCount - 2, by: 2) {
                    units.append(directoryData.legacyUInt16(at: nameOffset))
                }
                let name = String(decoding: units, as: UTF16.self)
                let type = directoryData[offset + 66]
                let start = directoryData.legacyUInt32(at: offset + 116)
                let lowSize = UInt64(directoryData.legacyUInt32(at: offset + 120))
                let highSize = majorVersion == 4
                    ? UInt64(directoryData.legacyUInt32(at: offset + 124)) << 32
                    : 0
                let size = highSize | lowSize
                guard size <= UInt64(Limits.maximumStreamSize) else {
                    throw ParserError("an OLE stream exceeds the supported size limit")
                }
                parsedEntries.append(
                    DirectoryEntry(name: name, type: type, startSector: start, size: Int(size))
                )
            }
            entries = parsedEntries
            guard let root = parsedEntries.first(where: { $0.type == 5 }) else {
                throw ParserError("the OLE root directory is missing")
            }
            miniStream = try Self.standardStream(
                start: root.startSector,
                size: root.size,
                data: data,
                sectorSize: sectorSize,
                fat: parsedFAT
            )
            let firstMiniFAT = data.legacyUInt32(at: 60)
            let miniFATSectorCount = Int(data.legacyUInt32(at: 64))
            if miniFATSectorCount > 0 {
                let miniFATData = try Self.standardStream(
                    start: firstMiniFAT,
                    size: miniFATSectorCount * sectorSize,
                    data: data,
                    sectorSize: sectorSize,
                    fat: parsedFAT
                )
                var parsedMiniFAT = [UInt32]()
                for offset in stride(from: 0, to: miniFATData.count, by: 4) {
                    parsedMiniFAT.append(miniFATData.legacyUInt32(at: offset))
                }
                miniFAT = parsedMiniFAT
            } else {
                miniFAT = []
            }
        }

        func stream(named name: String) throws -> Data? {
            guard let entry = entries.first(where: {
                $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                return nil
            }
            if entry.size < miniStreamCutoff {
                return try Self.miniStream(
                    start: entry.startSector,
                    size: entry.size,
                    miniStream: miniStream,
                    miniSectorSize: miniSectorSize,
                    miniFAT: miniFAT
                )
            }
            return try Self.standardStream(
                start: entry.startSector,
                size: entry.size,
                data: data,
                sectorSize: sectorSize,
                fat: fat
            )
        }

        private static func standardStream(
            start: UInt32,
            size: Int?,
            data: Data,
            sectorSize: Int,
            fat: [UInt32]
        ) throws -> Data {
            var result = Data()
            var current = start
            var seen = Set<UInt32>()
            while current != Constants.endOfChain {
                guard current < UInt32(fat.count), seen.insert(current).inserted else {
                    throw ParserError("an OLE sector chain is invalid")
                }
                result.append(try sector(current, in: data, sectorSize: sectorSize))
                if result.count > Limits.maximumStreamSize {
                    throw ParserError("an OLE stream exceeds the supported size limit")
                }
                current = fat[Int(current)]
                if current == Constants.freeSector || current == Constants.fatSector
                    || current == Constants.difatSector {
                    throw ParserError("an OLE sector chain ends in an invalid marker")
                }
            }
            if let size {
                guard result.count >= size else {
                    throw ParserError("an OLE stream is shorter than declared")
                }
                result.count = size
            }
            return result
        }

        private static func miniStream(
            start: UInt32,
            size: Int,
            miniStream: Data,
            miniSectorSize: Int,
            miniFAT: [UInt32]
        ) throws -> Data {
            var result = Data()
            var current = start
            var seen = Set<UInt32>()
            while current != Constants.endOfChain, result.count < size {
                guard current < UInt32(miniFAT.count), seen.insert(current).inserted else {
                    throw ParserError("an OLE mini-sector chain is invalid")
                }
                let offset = Int(current) * miniSectorSize
                guard offset + miniSectorSize <= miniStream.count else {
                    throw ParserError("an OLE mini-sector lies outside the mini stream")
                }
                result.append(miniStream.subdata(in: offset..<(offset + miniSectorSize)))
                current = miniFAT[Int(current)]
            }
            guard result.count >= size else {
                throw ParserError("an OLE mini stream is shorter than declared")
            }
            result.count = size
            return result
        }

        private static func sector(
            _ id: UInt32,
            in data: Data,
            sectorSize: Int
        ) throws -> Data {
            let offset = (Int(id) + 1) * sectorSize
            guard offset >= sectorSize, offset + sectorSize <= data.count else {
                throw ParserError("an OLE sector lies outside the file")
            }
            return data.subdata(in: offset..<(offset + sectorSize))
        }

        private struct DirectoryEntry {
            let name: String
            let type: UInt8
            let startSector: UInt32
            let size: Int
        }

        private enum Constants {
            static let freeSector: UInt32 = 0xFFFF_FFFF
            static let endOfChain: UInt32 = 0xFFFF_FFFE
            static let fatSector: UInt32 = 0xFFFF_FFFD
            static let difatSector: UInt32 = 0xFFFF_FFFC
        }
    }

    private enum BIFFParser {
        static func parse(_ data: Data) throws -> SpreadsheetWorkbook {
            let records = try records(in: data)
            guard let first = records.first,
                  first.id == 0x0809,
                  first.payload.legacyUInt16(at: 2) == 0x0005 else {
                throw ParserError("the Excel workbook-global BOF record is missing")
            }
            if records.contains(where: { $0.id == 0x002F }) {
                throw ParserError("encrypted XLS workbooks are not supported")
            }
            let sharedStrings = try parseSharedStrings(records)
            var bounds = [BoundSheet]()
            var hasUnsupportedObjects = false
            for record in records where record.id == 0x0085 {
                guard record.payload.count >= 8 else {
                    throw ParserError("an XLS sheet directory record is invalid")
                }
                let type = record.payload[5]
                let name = try biffShortString(record.payload, at: 6)
                if type == 0 {
                    bounds.append(
                        BoundSheet(offset: Int(record.payload.legacyUInt32(at: 0)), name: name)
                    )
                } else {
                    hasUnsupportedObjects = true
                }
            }
            guard !bounds.isEmpty else {
                throw ParserError("the XLS workbook contains no worksheets")
            }
            guard bounds.count <= Limits.maximumSheets else {
                throw ParserError("the XLS workbook contains too many sheets")
            }

            var workbook = SpreadsheetWorkbook(sheets: [])
            var expandedCellCount = 0
            for bound in bounds {
                let parsed = try parseSheet(
                    data,
                    at: bound.offset,
                    sharedStrings: sharedStrings,
                    maximumCells: Limits.maximumCells - expandedCellCount
                )
                expandedCellCount += parsed.expandedCellCount
                workbook.sheets.append(SpreadsheetSheet(name: bound.name, rows: parsed.rows))
                workbook.hasFlattenedMerges = workbook.hasFlattenedMerges || parsed.hasMerges
                workbook.hasFormulaWithoutResult = workbook.hasFormulaWithoutResult
                    || parsed.hasFormulaWithoutResult
                hasUnsupportedObjects = hasUnsupportedObjects || parsed.hasUnsupportedObjects
            }
            workbook.hasUnsupportedObjects = hasUnsupportedObjects
            return workbook
        }

        /// Liest BIFF-Records ab `start`.
        ///
        /// `stopAfterID` beendet den Lauf nach dem ersten Record dieser Art.
        /// Für ein einzelnes Blatt ist das der EOF-Record: Ohne ihn würde für
        /// jedes Blatt der gesamte restliche Arbeitsmappen-Stream eingelesen und
        /// jede Nutzlast kopiert — bei bis zu 256 Blättern also immer wieder von
        /// vorn, obwohl die Auswertung ohnehin am ersten EOF endet.
        private static func records(
            in data: Data,
            start: Int = 0,
            stopAfterID: UInt16? = nil
        ) throws -> [Record] {
            var result = [Record]()
            var offset = start
            while offset + 4 <= data.count {
                let id = data.legacyUInt16(at: offset)
                let length = Int(data.legacyUInt16(at: offset + 2))
                guard offset + 4 + length <= data.count else {
                    throw ParserError("an XLS BIFF record extends beyond the workbook stream")
                }
                result.append(
                    Record(
                        id: id,
                        offset: offset,
                        payload: data.subdata(in: (offset + 4)..<(offset + 4 + length))
                    )
                )
                offset += 4 + length
                if id == stopAfterID {
                    break
                }
            }
            return result
        }

        private static func parseSharedStrings(_ records: [Record]) throws -> [String] {
            guard let index = records.firstIndex(where: { $0.id == 0x00FC }) else {
                return []
            }
            var segments = [records[index].payload]
            var next = index + 1
            while next < records.count, records[next].id == 0x003C {
                segments.append(records[next].payload)
                next += 1
            }
            var cursor = SegmentedCursor(segments: segments)
            _ = try cursor.readUInt32()
            let uniqueCount = Int(try cursor.readUInt32())
            guard uniqueCount <= Limits.maximumSharedStrings else {
                throw ParserError("the XLS shared-string table exceeds the supported limit")
            }
            var strings = [String]()
            strings.reserveCapacity(uniqueCount)
            for _ in 0..<uniqueCount {
                strings.append(try cursor.readUnicodeString())
            }
            return strings
        }

        private static func parseSheet(
            _ data: Data,
            at offset: Int,
            sharedStrings: [String],
            maximumCells: Int
        ) throws -> SheetResult {
            guard offset >= 0, offset + 8 <= data.count,
                  data.legacyUInt16(at: offset) == 0x0809 else {
                throw ParserError("an XLS worksheet BOF offset is invalid")
            }
            let sheetRecords = try records(in: data, start: offset, stopAfterID: 0x000A)
            var cells = [Int: [Int: SpreadsheetCell]]()
            var hasMerges = false
            var hasFormulaWithoutResult = false
            var hasUnsupportedObjects = false
            var pendingStringFormula: (row: Int, column: Int, formula: String?)?

            for record in sheetRecords.dropFirst() {
                if record.id == 0x000A { break }
                switch record.id {
                case 0x00FD: // LABELSST
                    guard record.payload.count >= 10 else { throw ParserError("an XLS text cell is invalid") }
                    let index = Int(record.payload.legacyUInt32(at: 6))
                    guard sharedStrings.indices.contains(index) else {
                        throw ParserError("an XLS shared-string index is invalid")
                    }
                    try setCell(
                        .init(value: .string(sharedStrings[index]), displayText: sharedStrings[index], formula: nil),
                        row: Int(record.payload.legacyUInt16(at: 0)),
                        column: Int(record.payload.legacyUInt16(at: 2)),
                        in: &cells
                    )
                case 0x0203: // NUMBER
                    guard record.payload.count >= 14 else { throw ParserError("an XLS number cell is invalid") }
                    let number = record.payload.legacyDouble(at: 6)
                    let text = format(number)
                    try setCell(
                        .init(value: .number(text), displayText: text, formula: nil),
                        row: Int(record.payload.legacyUInt16(at: 0)),
                        column: Int(record.payload.legacyUInt16(at: 2)),
                        in: &cells
                    )
                case 0x027E: // RK
                    guard record.payload.count >= 10 else { throw ParserError("an XLS RK cell is invalid") }
                    let text = format(decodeRK(record.payload.legacyUInt32(at: 6)))
                    try setCell(
                        .init(value: .number(text), displayText: text, formula: nil),
                        row: Int(record.payload.legacyUInt16(at: 0)),
                        column: Int(record.payload.legacyUInt16(at: 2)),
                        in: &cells
                    )
                case 0x00BD: // MULRK
                    try parseMultipleRK(record.payload, into: &cells)
                case 0x0205: // BOOLERR
                    guard record.payload.count >= 8 else { throw ParserError("an XLS boolean cell is invalid") }
                    let isError = record.payload[7] != 0
                    let text = isError ? "#ERROR" : (record.payload[6] == 0 ? "FALSE" : "TRUE")
                    try setCell(
                        .init(
                            value: isError ? .string(text) : .boolean(record.payload[6] != 0),
                            displayText: text,
                            formula: nil
                        ),
                        row: Int(record.payload.legacyUInt16(at: 0)),
                        column: Int(record.payload.legacyUInt16(at: 2)),
                        in: &cells
                    )
                case 0x0006: // FORMULA
                    guard record.payload.count >= 14 else { throw ParserError("an XLS formula cell is invalid") }
                    let row = Int(record.payload.legacyUInt16(at: 0))
                    let column = Int(record.payload.legacyUInt16(at: 2))
                    let formulaMarker = "BIFF formula"
                    if record.payload[12] == 0xFF, record.payload[13] == 0xFF {
                        switch record.payload[6] {
                        case 0:
                            pendingStringFormula = (row, column, formulaMarker)
                        case 1:
                            let value = record.payload[8] != 0
                            try setCell(
                                .init(value: .boolean(value), displayText: value ? "TRUE" : "FALSE", formula: formulaMarker),
                                row: row, column: column, in: &cells
                            )
                        case 2:
                            try setCell(
                                .init(value: .string("#ERROR"), displayText: "#ERROR", formula: formulaMarker),
                                row: row, column: column, in: &cells
                            )
                        default:
                            hasFormulaWithoutResult = true
                            try setCell(.init(value: .empty, displayText: "", formula: formulaMarker), row: row, column: column, in: &cells)
                        }
                    } else {
                        let text = format(record.payload.legacyDouble(at: 6))
                        try setCell(.init(value: .number(text), displayText: text, formula: formulaMarker), row: row, column: column, in: &cells)
                    }
                case 0x0207: // STRING result after FORMULA
                    if let pending = pendingStringFormula {
                        let text = try biffLongString(record.payload)
                        try setCell(
                            .init(value: .string(text), displayText: text, formula: pending.formula),
                            row: pending.row,
                            column: pending.column,
                            in: &cells
                        )
                        pendingStringFormula = nil
                    }
                case 0x00E5:
                    hasMerges = true
                // OBJ, TXO, MSODRAWING, MSODRAWINGGROUP und HLINK. Der sichtbare
                // Zelltext bleibt jeweils erhalten, das Objekt selbst und bei
                // HLINK das Linkziel nicht — deshalb die Verlustwarnung.
                case 0x005D, 0x01B6, 0x00EC, 0x00EB, 0x01B8:
                    hasUnsupportedObjects = true
                default:
                    break
                }
            }
            if let pendingStringFormula {
                hasFormulaWithoutResult = true
                try setCell(
                    .init(value: .empty, displayText: "", formula: pendingStringFormula.formula),
                    row: pendingStringFormula.row,
                    column: pendingStringFormula.column,
                    in: &cells
                )
            }
            let dense = try denseRows(cells, maximumCells: maximumCells)
            return SheetResult(
                rows: dense.rows,
                hasMerges: hasMerges,
                hasFormulaWithoutResult: hasFormulaWithoutResult,
                hasUnsupportedObjects: hasUnsupportedObjects,
                expandedCellCount: dense.expandedCellCount
            )
        }

        private static func setCell(
            _ cell: SpreadsheetCell,
            row: Int,
            column: Int,
            in cells: inout [Int: [Int: SpreadsheetCell]]
        ) throws {
            guard row >= 0, row < Limits.maximumRows,
                  column >= 0, column < Limits.maximumColumns else {
                throw ParserError("an XLS cell lies outside the supported row or column budget")
            }
            cells[row, default: [:]][column] = cell
        }

        private static func denseRows(
            _ cells: [Int: [Int: SpreadsheetCell]],
            maximumCells: Int
        ) throws -> (rows: [[SpreadsheetCell]], expandedCellCount: Int) {
            guard let maximumRow = cells.keys.max() else { return ([], 0) }
            var cellBudget = 0
            var rows = [[SpreadsheetCell]]()
            rows.reserveCapacity(maximumRow + 1)
            for rowIndex in 0...maximumRow {
                guard let sparse = cells[rowIndex], let maximumColumn = sparse.keys.max() else {
                    rows.append([])
                    continue
                }
                cellBudget += maximumColumn + 1
                guard cellBudget <= maximumCells else {
                    throw ParserError("the XLS sheet exceeds the expanded-cell budget")
                }
                var row = [SpreadsheetCell](repeating: .empty, count: maximumColumn + 1)
                for (column, cell) in sparse { row[column] = cell }
                rows.append(row)
            }
            return (rows, cellBudget)
        }

        private static func parseMultipleRK(
            _ payload: Data,
            into cells: inout [Int: [Int: SpreadsheetCell]]
        ) throws {
            guard payload.count >= 12, (payload.count - 6) % 6 == 0 else {
                throw ParserError("an XLS multiple-number record is invalid")
            }
            let row = Int(payload.legacyUInt16(at: 0))
            let firstColumn = Int(payload.legacyUInt16(at: 2))
            let lastColumn = Int(payload.legacyUInt16(at: payload.count - 2))
            let count = (payload.count - 6) / 6
            guard lastColumn - firstColumn + 1 == count else {
                throw ParserError("an XLS multiple-number column range is invalid")
            }
            for index in 0..<count {
                let text = format(decodeRK(payload.legacyUInt32(at: 6 + index * 6)))
                try setCell(
                    .init(value: .number(text), displayText: text, formula: nil),
                    row: row,
                    column: firstColumn + index,
                    in: &cells
                )
            }
        }

        private static func decodeRK(_ raw: UInt32) -> Double {
            let value: Double
            if raw & 0x2 != 0 {
                value = Double(Int32(bitPattern: raw) >> 2)
            } else {
                value = Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
            }
            return raw & 0x1 != 0 ? value / 100 : value
        }

        private static func format(_ number: Double) -> String {
            String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), number)
        }

        private static func biffShortString(_ data: Data, at offset: Int) throws -> String {
            guard offset + 2 <= data.count else { throw ParserError("an XLS sheet name is invalid") }
            let count = Int(data[offset])
            let isWide = data[offset + 1] & 0x1 != 0
            let start = offset + 2
            let byteCount = count * (isWide ? 2 : 1)
            guard start + byteCount <= data.count else { throw ParserError("an XLS sheet name is truncated") }
            return decodeCharacters(data.subdata(in: start..<(start + byteCount)), wide: isWide)
        }

        private static func biffLongString(_ data: Data) throws -> String {
            guard data.count >= 3 else { throw ParserError("an XLS formula string is invalid") }
            let count = Int(data.legacyUInt16(at: 0))
            let isWide = data[2] & 0x1 != 0
            let byteCount = count * (isWide ? 2 : 1)
            guard 3 + byteCount <= data.count else { throw ParserError("an XLS formula string is truncated") }
            return decodeCharacters(data.subdata(in: 3..<(3 + byteCount)), wide: isWide)
        }

        private static func decodeCharacters(_ data: Data, wide: Bool) -> String {
            if wide {
                var units = [UInt16]()
                for offset in stride(from: 0, to: data.count, by: 2) {
                    units.append(data.legacyUInt16(at: offset))
                }
                return String(decoding: units, as: UTF16.self)
            }
            return String(data: data, encoding: .isoLatin1)
                ?? String(decoding: data, as: UTF8.self)
        }

        private struct Record {
            let id: UInt16
            let offset: Int
            let payload: Data
        }

        private struct BoundSheet { let offset: Int; let name: String }

        private struct SheetResult {
            let rows: [[SpreadsheetCell]]
            let hasMerges: Bool
            let hasFormulaWithoutResult: Bool
            let hasUnsupportedObjects: Bool
            let expandedCellCount: Int
        }

        private struct SegmentedCursor {
            let segments: [Data]
            var segmentIndex = 0
            var offset = 0

            mutating func readUInt16() throws -> UInt16 {
                UInt16(try readRawByte()) | UInt16(try readRawByte()) << 8
            }

            mutating func readUInt32() throws -> UInt32 {
                UInt32(try readRawByte())
                    | UInt32(try readRawByte()) << 8
                    | UInt32(try readRawByte()) << 16
                    | UInt32(try readRawByte()) << 24
            }

            mutating func readUnicodeString() throws -> String {
                let characterCount = Int(try readUInt16())
                let flags = try readRawByte()
                var wide = flags & 0x1 != 0
                let richRunCount = flags & 0x8 != 0 ? Int(try readUInt16()) : 0
                let extensionSize = flags & 0x4 != 0 ? Int(try readUInt32()) : 0
                var remaining = characterCount
                var result = ""
                while remaining > 0 {
                    if offset == segments[segmentIndex].count {
                        try moveToNextSegment()
                        wide = try readRawByte() & 0x1 != 0
                    }
                    let bytesPerCharacter = wide ? 2 : 1
                    let available = (segments[segmentIndex].count - offset) / bytesPerCharacter
                    guard available > 0 else {
                        throw ParserError("an XLS shared string splits a character at a record boundary")
                    }
                    let count = min(remaining, available)
                    let byteCount = count * bytesPerCharacter
                    let chunk = segments[segmentIndex].subdata(in: offset..<(offset + byteCount))
                    result += BIFFParser.decodeCharacters(chunk, wide: wide)
                    offset += byteCount
                    remaining -= count
                }
                try skipRaw(richRunCount * 4 + extensionSize)
                return result
            }

            private mutating func readRawByte() throws -> UInt8 {
                while segmentIndex < segments.count, offset == segments[segmentIndex].count {
                    try moveToNextSegment()
                }
                guard segmentIndex < segments.count, offset < segments[segmentIndex].count else {
                    throw ParserError("the XLS shared-string table is truncated")
                }
                defer { offset += 1 }
                return segments[segmentIndex][offset]
            }

            private mutating func skipRaw(_ count: Int) throws {
                for _ in 0..<count { _ = try readRawByte() }
            }

            private mutating func moveToNextSegment() throws {
                guard segmentIndex + 1 < segments.count else {
                    throw ParserError("the XLS shared-string continuation is missing")
                }
                segmentIndex += 1
                offset = 0
            }
        }

        private enum Limits {
            static let maximumSheets = 256
            static let maximumRows = 100_000
            static let maximumColumns = 16_384
            static let maximumCells = 1_000_000
            static let maximumSharedStrings = 1_000_000
        }
    }

    private enum Limits {
        static let maximumStreamSize = 1_073_741_824
    }

    private struct ParserError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

private extension Data {
    func legacyUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func legacyUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func legacyDouble(at offset: Int) -> Double {
        guard offset >= 0, offset + 8 <= count else { return .nan }
        var bits: UInt64 = 0
        for index in 0..<8 { bits |= UInt64(self[offset + index]) << UInt64(index * 8) }
        return Double(bitPattern: bits)
    }
}
