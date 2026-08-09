import Foundation

enum XLSXWorkbookParser {
    static func parse(packageAt url: URL) throws -> SpreadsheetWorkbook {
        let metadata = try ZIPArchiveInspector.packageContents(
            at: url,
            entryNames: [
                "[Content_Types].xml",
                "xl/workbook.xml",
                "xl/_rels/workbook.xml.rels",
                "xl/sharedStrings.xml",
            ]
        )
        guard let contentTypes = metadata.entries["[Content_Types].xml"],
              let workbookXML = metadata.entries["xl/workbook.xml"],
              let relationshipsXML = metadata.entries["xl/_rels/workbook.xml.rels"] else {
            throw ParserError("the XLSX package is missing workbook metadata")
        }
        try validateMainContentType(contentTypes)

        let sheetDefinitions = try WorkbookParser.parse(workbookXML)
        guard !sheetDefinitions.isEmpty else {
            throw ParserError("xl/workbook.xml contains no sheets")
        }
        guard sheetDefinitions.count <= Limits.maximumSheets else {
            throw ParserError("the workbook contains too many sheets")
        }
        let relationships = try RelationshipParser.parse(relationshipsXML)
        // Ein Diagramm- oder Dialogblatt steht wie ein Arbeitsblatt in
        // `<sheets>`, hat aber keine Worksheet-Beziehung. Es wird übersprungen
        // und als nicht darstellbares Objekt gemeldet, statt die ganze
        // Arbeitsmappe scheitern zu lassen.
        var worksheetDefinitions = [SheetDefinition]()
        var sheetPaths = [String]()
        var hasSkippedSheets = false
        for definition in sheetDefinitions {
            if let target = relationships.worksheets[definition.relationshipID] {
                worksheetDefinitions.append(definition)
                sheetPaths.append(try normalizedWorksheetPath(target))
            } else if relationships.otherSheetIDs.contains(definition.relationshipID) {
                hasSkippedSheets = true
            } else {
                throw ParserError("a workbook sheet relationship is missing")
            }
        }
        guard !worksheetDefinitions.isEmpty else {
            throw ParserError("the workbook contains no readable worksheets")
        }

        let worksheetPackage = try ZIPArchiveInspector.packageContents(
            at: url,
            entryNames: sheetPaths
        )
        let sharedStrings: [String]
        if let xml = metadata.entries["xl/sharedStrings.xml"] {
            sharedStrings = try SharedStringsParser.parse(xml)
        } else {
            sharedStrings = []
        }

        var result = SpreadsheetWorkbook(sheets: [])
        var expandedCellCount = 0
        var hasHyperlinks = false
        for (definition, path) in zip(worksheetDefinitions, sheetPaths) {
            guard let xml = worksheetPackage.entries[path] else {
                throw ParserError("the worksheet part is missing: \(path)")
            }
            let parsed = try WorksheetParser.parse(
                xml,
                sharedStrings: sharedStrings,
                maximumCells: Limits.maximumCells - expandedCellCount
            )
            expandedCellCount += parsed.expandedCellCount
            result.sheets.append(SpreadsheetSheet(name: definition.name, rows: parsed.rows))
            result.hasFlattenedMerges = result.hasFlattenedMerges || parsed.hasMerges
            result.hasFormulaWithoutResult = result.hasFormulaWithoutResult
                || parsed.hasFormulaWithoutResult
            hasHyperlinks = hasHyperlinks || parsed.hasHyperlinks
        }
        // `xl/threadedComments/…` ist der Ablageort moderner Excel-Kommentare;
        // ohne ihn blieben genau die still verworfen.
        result.hasUnsupportedObjects = hasSkippedSheets || hasHyperlinks
            || metadata.entryNames.contains {
                $0.hasPrefix("xl/charts/")
                    || $0.hasPrefix("xl/drawings/")
                    || $0.hasPrefix("xl/media/")
                    || $0.hasPrefix("xl/comments")
                    || $0.hasPrefix("xl/threadedComments/")
                    || $0 == "xl/vbaProject.bin"
            }
        return result
    }

    static func looksLikeXLSX(packageAt url: URL) throws -> Bool {
        let metadata = try ZIPArchiveInspector.packageContents(
            at: url,
            entryNames: ["[Content_Types].xml", "xl/workbook.xml", "xl/_rels/workbook.xml.rels"]
        )
        guard let contentTypes = metadata.entries["[Content_Types].xml"],
              metadata.entryNames.contains("xl/workbook.xml"),
              metadata.entryNames.contains("xl/_rels/workbook.xml.rels") else {
            return false
        }
        do {
            try validateMainContentType(contentTypes)
            return true
        } catch {
            return false
        }
    }

    private static func validateMainContentType(_ xml: Data) throws {
        let delegate = ContentTypesDelegate()
        try parse(xml, delegate: delegate)
        guard delegate.hasValidRoot,
              delegate.mainContentTypes == Set([
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
              ]) else {
            throw ParserError("xl/workbook.xml has no supported XLSX main content type")
        }
    }

    private static func normalizedWorksheetPath(_ target: String) throws -> String {
        guard !target.isEmpty,
              !target.contains("\\"),
              URL(string: target)?.scheme == nil else {
            throw ParserError("an XLSX worksheet relationship is unsafe: \(target)")
        }
        let path = target.hasPrefix("/")
            ? String(target.dropFirst())
            : "xl/\(target)"
        let components = NSString(string: path).pathComponents
        guard !components.contains(".."), path.hasPrefix("xl/") else {
            throw ParserError("an XLSX worksheet relationship leaves the package: \(target)")
        }
        return path
    }

    private static func parse(_ xml: Data, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
    }

    private final class ContentTypesDelegate: NSObject, XMLParserDelegate {
        var hasValidRoot = false
        var mainContentTypes = Set<String>()
        private var sawRoot = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if !sawRoot {
                sawRoot = true
                hasValidRoot = elementName == "Types"
                    && namespaceURI == Namespaces.contentTypes
            }
            guard namespaceURI == Namespaces.contentTypes,
                  elementName == "Override",
                  xlsxAttribute("PartName", in: attributeDict) == "/xl/workbook.xml",
                  let type = xlsxAttribute("ContentType", in: attributeDict) else {
                return
            }
            mainContentTypes.insert(type.lowercased())
        }
    }

    private struct SheetDefinition {
        let name: String
        let relationshipID: String
    }

    private enum WorkbookParser {
        static func parse(_ xml: Data) throws -> [SheetDefinition] {
            let delegate = Delegate()
            try XLSXWorkbookParser.parse(xml, delegate: delegate)
            guard delegate.hasValidRoot, delegate.failure == nil else {
                throw ParserError(delegate.failure ?? "xl/workbook.xml has no valid workbook root")
            }
            return delegate.sheets
        }

        private final class Delegate: NSObject, XMLParserDelegate {
            var sheets = [SheetDefinition]()
            var hasValidRoot = false
            var failure: String?
            private var sawRoot = false
            private let prefixes = NamespacePrefixTracker()

            func parser(
                _ parser: XMLParser,
                didStartMappingPrefix prefix: String,
                toURI namespaceURI: String
            ) {
                prefixes.startMapping(prefix: prefix, uri: namespaceURI)
            }

            func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
                prefixes.endMapping(prefix: prefix)
            }

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                if !sawRoot {
                    sawRoot = true
                    hasValidRoot = elementName == "workbook"
                        && namespaceURI == Namespaces.spreadsheet
                }
                guard namespaceURI == Namespaces.spreadsheet, elementName == "sheet" else {
                    return
                }
                guard let name = xlsxAttribute("name", in: attributeDict),
                      let relationshipID = prefixes.attributeValue(
                        localName: "id",
                        namespaceURI: Namespaces.officeDocumentRelationships,
                        in: attributeDict
                      ) else {
                    failure = "an XLSX sheet declaration is incomplete"
                    return
                }
                sheets.append(SheetDefinition(name: name, relationshipID: relationshipID))
            }
        }
    }

    /// Die Beziehungen der Arbeitsmappe, getrennt nach lesbaren Arbeitsblättern
    /// und den übrigen Blattarten. Ohne diese Trennung ließe sich ein
    /// Diagrammblatt nicht von einer wirklich fehlenden Beziehung unterscheiden.
    private struct WorkbookRelationships {
        let worksheets: [String: String]
        let otherSheetIDs: Set<String>
    }

    private enum RelationshipParser {
        static func parse(_ xml: Data) throws -> WorkbookRelationships {
            let delegate = Delegate()
            try XLSXWorkbookParser.parse(xml, delegate: delegate)
            guard delegate.hasValidRoot, delegate.failure == nil else {
                throw ParserError(
                    delegate.failure ?? "xl/_rels/workbook.xml.rels has no valid Relationships root"
                )
            }
            if let unsafeTarget = delegate.unsafeTarget {
                throw ParserError("an external XLSX relationship is not allowed: \(unsafeTarget)")
            }
            return WorkbookRelationships(
                worksheets: delegate.worksheets,
                otherSheetIDs: delegate.otherSheetIDs
            )
        }

        /// Blattarten, die OOXML kennt, die aber kein Zellgitter enthalten.
        private static let otherSheetTypes = ["/chartsheet", "/dialogsheet"]

        private final class Delegate: NSObject, XMLParserDelegate {
            var worksheets = [String: String]()
            var otherSheetIDs = Set<String>()
            var unsafeTarget: String?
            var hasValidRoot = false
            var failure: String?
            private var sawRoot = false

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                if !sawRoot {
                    sawRoot = true
                    hasValidRoot = elementName == "Relationships"
                        && namespaceURI == Namespaces.relationships
                }
                guard namespaceURI == Namespaces.relationships,
                      elementName == "Relationship",
                      let id = xlsxAttribute("Id", in: attributeDict),
                      let target = xlsxAttribute("Target", in: attributeDict),
                      let type = xlsxAttribute("Type", in: attributeDict)?.lowercased() else {
                    return
                }
                if otherSheetTypes.contains(where: type.hasSuffix) {
                    otherSheetIDs.insert(id)
                    return
                }
                guard type.hasSuffix("/worksheet") else {
                    return
                }
                if xlsxAttribute("TargetMode", in: attributeDict)?.lowercased() == "external" {
                    unsafeTarget = target
                } else {
                    guard worksheets[id] == nil else {
                        failure = "an XLSX worksheet relationship ID is duplicated"
                        return
                    }
                    worksheets[id] = target
                }
            }
        }
    }

    private enum SharedStringsParser {
        static func parse(_ xml: Data) throws -> [String] {
            let delegate = Delegate()
            let parser = XMLParser(data: xml)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            guard parser.parse(), delegate.failure == nil else {
                throw delegate.failure ?? parser.parserError ?? CocoaError(.fileReadCorruptFile)
            }
            guard delegate.hasValidRoot else {
                throw ParserError("xl/sharedStrings.xml has no valid shared-string root")
            }
            return delegate.strings
        }

        private final class Delegate: NSObject, XMLParserDelegate {
            var strings = [String]()
            var failure: Error?
            var hasValidRoot = false
            private var current: String?
            private var capturesText = false
            private var sawRoot = false

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                if !sawRoot {
                    sawRoot = true
                    hasValidRoot = elementName == "sst"
                        && namespaceURI == Namespaces.spreadsheet
                }
                guard namespaceURI == Namespaces.spreadsheet else { return }
                if elementName == "si" { current = "" }
                if elementName == "t", current != nil { capturesText = true }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if capturesText { current?.append(string) }
            }

            func parser(
                _ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?
            ) {
                guard namespaceURI == Namespaces.spreadsheet else { return }
                if elementName == "t" { capturesText = false }
                if elementName == "si", let current {
                    guard strings.count < Limits.maximumSharedStrings else {
                        failure = ParserError("the XLSX shared-string table exceeds the budget")
                        parser.abortParsing()
                        return
                    }
                    strings.append(current)
                    self.current = nil
                }
            }
        }
    }

    private struct WorksheetInspection {
        let rows: [[SpreadsheetCell]]
        let hasMerges: Bool
        let hasFormulaWithoutResult: Bool
        let hasHyperlinks: Bool
        let expandedCellCount: Int
    }

    private enum WorksheetParser {
        static func parse(
            _ xml: Data,
            sharedStrings: [String],
            maximumCells: Int
        ) throws -> WorksheetInspection {
            let delegate = Delegate(sharedStrings: sharedStrings, maximumCells: maximumCells)
            let parser = XMLParser(data: xml)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            guard parser.parse(), delegate.failure == nil else {
                throw delegate.failure ?? parser.parserError ?? CocoaError(.fileReadCorruptFile)
            }
            guard delegate.hasValidRoot else {
                throw ParserError("an XLSX worksheet has no valid worksheet root")
            }
            return WorksheetInspection(
                rows: delegate.rows,
                hasMerges: delegate.hasMerges,
                hasFormulaWithoutResult: delegate.hasFormulaWithoutResult,
                hasHyperlinks: delegate.hasHyperlinks,
                expandedCellCount: delegate.expandedCellCount
            )
        }

        private final class Delegate: NSObject, XMLParserDelegate {
            var rows = [[SpreadsheetCell]]()
            var hasMerges = false
            var hasFormulaWithoutResult = false
            var hasHyperlinks = false
            var failure: Error?
            var hasValidRoot = false

            private let sharedStrings: [String]
            private let maximumCells: Int
            private var currentRow: [SpreadsheetCell]?
            private var currentCell: CellBuilder?
            private var capture: Capture?
            private(set) var expandedCellCount = 0
            private var sawRoot = false
            /// Breite, die der Zellparser bereits gegen das Gesamtbudget
            /// gerechnet hat. Das bleibt auch für eine später weggetrimmte leere
            /// Zelle wahr, auf die ein Hyperlink seinen Anzeigetext schreibt.
            private var accountedRowWidths = [Int]()

            init(sharedStrings: [String], maximumCells: Int) {
                self.sharedStrings = sharedStrings
                self.maximumCells = maximumCells
            }

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                guard failure == nil else { return }
                if !sawRoot {
                    sawRoot = true
                    hasValidRoot = elementName == "worksheet"
                        && namespaceURI == Namespaces.spreadsheet
                }
                guard namespaceURI == Namespaces.spreadsheet else { return }
                if elementName == "row" {
                    let rowNumber = Int(xlsxAttribute("r", in: attributeDict) ?? "")
                        ?? rows.count + 1
                    guard rowNumber > 0, rowNumber <= Limits.maximumRows,
                          rowNumber >= rows.count + 1 else {
                        return fail("an XLSX row index is invalid or exceeds the budget", parser: parser)
                    }
                    while rows.count + 1 < rowNumber {
                        rows.append([])
                        accountedRowWidths.append(0)
                    }
                    currentRow = []
                } else if elementName == "c", let row = currentRow {
                    // Das Attribut `r` ist laut OOXML freigestellt. Fehlt es,
                    // steht die Zelle in der nächsten freien Spalte dieser Zeile.
                    let column: Int?
                    if let reference = xlsxAttribute("r", in: attributeDict) {
                        column = columnIndex(reference)
                    } else {
                        column = row.count
                    }
                    guard let column, column < Limits.maximumColumns else {
                        return fail("an XLSX cell reference exceeds the column budget", parser: parser)
                    }
                    currentCell = CellBuilder(
                        column: column,
                        type: xlsxAttribute("t", in: attributeDict)
                    )
                } else if elementName == "v", currentCell != nil {
                    capture = .value
                } else if elementName == "f", currentCell != nil {
                    // Eine Folgezelle einer gemeinsamen Formel darf leer sein
                    // (`<f t="shared" si="0"/>`). Deshalb zählt hier, dass das
                    // Element überhaupt da war, nicht sein Text.
                    currentCell?.hasFormulaElement = true
                    capture = .formula
                } else if elementName == "t", currentCell?.type == "inlineStr" {
                    capture = .inlineText
                } else if elementName == "mergeCell" {
                    hasMerges = true
                } else if elementName == "hyperlink" {
                    hasHyperlinks = true
                    guard let reference = xlsxAttribute("ref", in: attributeDict),
                          let display = xlsxAttribute("display", in: attributeDict),
                          !display.isEmpty else {
                        return
                    }
                    do {
                        try applyHyperlinkDisplay(display, to: reference)
                    } catch {
                        fail(error.localizedDescription, parser: parser)
                    }
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                switch capture {
                case .value: currentCell?.rawValue.append(string)
                case .formula: currentCell?.formula.append(string)
                case .inlineText: currentCell?.inlineText.append(string)
                case nil: break
                }
            }

            func parser(
                _ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?
            ) {
                guard namespaceURI == Namespaces.spreadsheet else { return }
                if elementName == "v" || elementName == "f" || elementName == "t" {
                    capture = nil
                } else if elementName == "c" {
                    finishCell(parser: parser)
                } else if elementName == "row", let row = currentRow {
                    accountedRowWidths.append(row.count)
                    rows.append(trimmed(row))
                    currentRow = nil
                    guard rows.count <= Limits.maximumRows else {
                        return fail("the XLSX sheet exceeds the row budget", parser: parser)
                    }
                }
            }

            private func finishCell(parser: XMLParser) {
                guard let builder = currentCell, currentRow != nil else { return }
                defer { currentCell = nil }
                let cellsToAppend = builder.column - currentRow!.count + 1
                guard cellsToAppend > 0,
                      expandedCellCount <= maximumCells - cellsToAppend else {
                    return fail("the XLSX sheet exceeds the expanded-cell budget", parser: parser)
                }
                while currentRow!.count < builder.column { currentRow!.append(.empty) }
                guard currentRow!.count == builder.column else {
                    return fail("XLSX cells are not in increasing column order", parser: parser)
                }
                do {
                    let cell = try builder.cell(sharedStrings: sharedStrings)
                    currentRow!.append(cell)
                    expandedCellCount += cellsToAppend
                    if builder.hasFormulaElement, cell.displayText.isEmpty {
                        hasFormulaWithoutResult = true
                    }
                } catch {
                    fail(error.localizedDescription, parser: parser)
                }
            }

            private func applyHyperlinkDisplay(_ display: String, to reference: String) throws {
                let range = try cellRange(reference)
                guard range.lastRow < Limits.maximumRows else {
                    throw ParserError("an XLSX hyperlink exceeds the row budget")
                }
                guard range.lastColumn < Limits.maximumColumns else {
                    throw ParserError("an XLSX hyperlink exceeds the column budget")
                }

                var addedCells = 0
                for rowIndex in range.firstRow...range.lastRow {
                    let accountedWidth = accountedRowWidths.indices.contains(rowIndex)
                        ? accountedRowWidths[rowIndex]
                        : 0
                    addedCells += max(0, range.lastColumn + 1 - accountedWidth)
                    guard expandedCellCount <= maximumCells - addedCells else {
                        throw ParserError("the XLSX sheet exceeds the expanded-cell budget")
                    }
                }

                while rows.count <= range.lastRow {
                    rows.append([])
                    accountedRowWidths.append(0)
                }
                for rowIndex in range.firstRow...range.lastRow {
                    if rows[rowIndex].count <= range.lastColumn {
                        rows[rowIndex].append(contentsOf: repeatElement(
                            .empty,
                            count: range.lastColumn + 1 - rows[rowIndex].count
                        ))
                    }
                    for columnIndex in range.firstColumn...range.lastColumn
                    where rows[rowIndex][columnIndex].isEmpty {
                        rows[rowIndex][columnIndex] = SpreadsheetCell(
                            value: .string(display),
                            displayText: display,
                            formula: nil
                        )
                    }
                    accountedRowWidths[rowIndex] = max(
                        accountedRowWidths[rowIndex],
                        range.lastColumn + 1
                    )
                }
                expandedCellCount += addedCells
            }

            private func fail(_ reason: String, parser: XMLParser) {
                guard failure == nil else { return }
                failure = ParserError(reason)
                parser.abortParsing()
            }
        }

        private struct CellBuilder {
            let column: Int
            let type: String?
            var rawValue = ""
            var formula = ""
            /// Wahr, sobald ein `<f>`-Element auftauchte — auch ein leeres.
            var hasFormulaElement = false
            var inlineText = ""

            func cell(sharedStrings: [String]) throws -> SpreadsheetCell {
                // Eine Zelle mit `<f/>`-Element ist eine Formelzelle, auch wenn
                // der Formeltext bei einer gemeinsamen Formel nur in der ersten
                // Zelle steht. Sonst gälte sie als leer und fiele weg.
                let formulaValue = formula.isEmpty ? (hasFormulaElement ? "" : nil) : formula
                switch type {
                case "s":
                    guard let index = Int(rawValue), sharedStrings.indices.contains(index) else {
                        throw ParserError("an XLSX shared-string index is invalid")
                    }
                    let text = sharedStrings[index]
                    return SpreadsheetCell(value: .string(text), displayText: text, formula: formulaValue)
                case "inlineStr":
                    return SpreadsheetCell(
                        value: .string(inlineText),
                        displayText: inlineText,
                        formula: formulaValue
                    )
                case "b":
                    let value = rawValue == "1" || rawValue.lowercased() == "true"
                    return SpreadsheetCell(
                        value: .boolean(value),
                        displayText: value ? "TRUE" : "FALSE",
                        formula: formulaValue
                    )
                case "str", "e":
                    return SpreadsheetCell(
                        value: .string(rawValue),
                        displayText: rawValue,
                        formula: formulaValue
                    )
                default:
                    return SpreadsheetCell(
                        value: rawValue.isEmpty ? .empty : .number(rawValue),
                        displayText: rawValue,
                        formula: formulaValue
                    )
                }
            }
        }

        private enum Capture { case value, formula, inlineText }
    }

    private static func columnIndex(_ reference: String) -> Int? {
        var value = 0
        var foundLetter = false
        for scalar in reference.unicodeScalars {
            if scalar.value >= 65, scalar.value <= 90 {
                foundLetter = true
                value = value * 26 + Int(scalar.value - 64)
            } else if scalar.value >= 97, scalar.value <= 122 {
                foundLetter = true
                value = value * 26 + Int(scalar.value - 96)
            } else {
                break
            }
        }
        return foundLetter ? value - 1 : nil
    }

    private static func cellRange(
        _ reference: String
    ) throws -> (firstRow: Int, lastRow: Int, firstColumn: Int, lastColumn: Int) {
        let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let first = cellCoordinate(parts[0]),
              let last = cellCoordinate(parts.last!) else {
            throw ParserError("an XLSX hyperlink cell reference is invalid")
        }
        return (
            min(first.row, last.row),
            max(first.row, last.row),
            min(first.column, last.column),
            max(first.column, last.column)
        )
    }

    private static func cellCoordinate(_ reference: Substring) -> (row: Int, column: Int)? {
        let letters = reference.prefix { $0.isASCII && $0.isLetter }
        let digits = reference[letters.endIndex...]
        guard !letters.isEmpty,
              !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let row = Int(digits),
              row > 0,
              let column = columnIndex(String(letters)) else {
            return nil
        }
        return (row - 1, column)
    }

    private static func trimmed(_ row: [SpreadsheetCell]) -> [SpreadsheetCell] {
        var row = row
        while row.last?.isEmpty == true { row.removeLast() }
        return row
    }

    private enum Limits {
        static let maximumSheets = 256
        static let maximumRows = 100_000
        static let maximumColumns = 16_384
        static let maximumCells = 1_000_000
        static let maximumSharedStrings = 1_000_000
    }

    private enum Namespaces {
        static let contentTypes =
            "http://schemas.openxmlformats.org/package/2006/content-types"
        static let relationships =
            "http://schemas.openxmlformats.org/package/2006/relationships"
        static let officeDocumentRelationships =
            "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        static let spreadsheet =
            "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    }

    private struct ParserError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

private final class NamespacePrefixTracker {
    private var uris = [String: [String]]()

    func startMapping(prefix: String, uri: String) {
        uris[prefix, default: []].append(uri)
    }

    func endMapping(prefix: String) {
        guard var stack = uris[prefix], !stack.isEmpty else { return }
        stack.removeLast()
        uris[prefix] = stack.isEmpty ? nil : stack
    }

    func attributeValue(
        localName: String,
        namespaceURI: String,
        in attributes: [String: String]
    ) -> String? {
        for (name, value) in attributes {
            guard let separator = name.firstIndex(of: ":"),
                  name[name.index(after: separator)...] == localName,
                  uris[String(name[..<separator])]?.last == namespaceURI else {
                continue
            }
            return value
        }
        return nil
    }
}

private func xlsxAttribute(_ localName: String, in attributes: [String: String]) -> String? {
    // OOXML- und OPC-Attribute sind hier unpräfigiert. Das einzige in diesem
    // Parser ausgewertete namespaced Attribut (`r:id`) läuft ausdrücklich über
    // `NamespacePrefixTracker`, damit kein beliebiges fremdes Präfix genügt.
    attributes[localName]
}
