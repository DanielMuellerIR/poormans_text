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
        let sheetPaths = try sheetDefinitions.map { definition -> String in
            guard let target = relationships[definition.relationshipID] else {
                throw ParserError("a workbook sheet relationship is missing")
            }
            return try normalizedWorksheetPath(target)
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
        for (definition, path) in zip(sheetDefinitions, sheetPaths) {
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
        }
        result.hasUnsupportedObjects = metadata.entryNames.contains {
            $0.hasPrefix("xl/charts/")
                || $0.hasPrefix("xl/drawings/")
                || $0.hasPrefix("xl/media/")
                || $0.hasPrefix("xl/comments")
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
                      let relationshipID = xlsxAttribute("id", in: attributeDict) else {
                    failure = "an XLSX sheet declaration is incomplete"
                    parser.abortParsing()
                    return
                }
                sheets.append(SheetDefinition(name: name, relationshipID: relationshipID))
            }
        }
    }

    private enum RelationshipParser {
        static func parse(_ xml: Data) throws -> [String: String] {
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
            return delegate.worksheets
        }

        private final class Delegate: NSObject, XMLParserDelegate {
            var worksheets = [String: String]()
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
                      xlsxAttribute("Type", in: attributeDict)?.lowercased()
                        .hasSuffix("/worksheet") == true else {
                    return
                }
                if xlsxAttribute("TargetMode", in: attributeDict)?.lowercased() == "external" {
                    unsafeTarget = target
                } else {
                    guard worksheets[id] == nil else {
                        failure = "an XLSX worksheet relationship ID is duplicated"
                        parser.abortParsing()
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
                expandedCellCount: delegate.expandedCellCount
            )
        }

        private final class Delegate: NSObject, XMLParserDelegate {
            var rows = [[SpreadsheetCell]]()
            var hasMerges = false
            var hasFormulaWithoutResult = false
            var failure: Error?
            var hasValidRoot = false

            private let sharedStrings: [String]
            private let maximumCells: Int
            private var currentRow: [SpreadsheetCell]?
            private var currentRowNumber = 0
            private var currentCell: CellBuilder?
            private var capture: Capture?
            private(set) var expandedCellCount = 0
            private var sawRoot = false

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
                    while rows.count + 1 < rowNumber { rows.append([]) }
                    currentRow = []
                    currentRowNumber = rowNumber
                } else if elementName == "c", currentRow != nil {
                    let reference = xlsxAttribute("r", in: attributeDict) ?? "A\(currentRowNumber)"
                    guard let column = columnIndex(reference), column < Limits.maximumColumns else {
                        return fail("an XLSX cell reference exceeds the column budget", parser: parser)
                    }
                    currentCell = CellBuilder(
                        column: column,
                        type: xlsxAttribute("t", in: attributeDict)
                    )
                } else if elementName == "v", currentCell != nil {
                    capture = .value
                } else if elementName == "f", currentCell != nil {
                    capture = .formula
                } else if elementName == "t", currentCell?.type == "inlineStr" {
                    capture = .inlineText
                } else if elementName == "mergeCell" {
                    hasMerges = true
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
                    if !builder.formula.isEmpty, cell.displayText.isEmpty {
                        hasFormulaWithoutResult = true
                    }
                } catch {
                    fail(error.localizedDescription, parser: parser)
                }
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
            var inlineText = ""

            func cell(sharedStrings: [String]) throws -> SpreadsheetCell {
                let formulaValue = formula.isEmpty ? nil : formula
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
        static let spreadsheet =
            "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    }

    private struct ParserError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

private func xlsxAttribute(_ localName: String, in attributes: [String: String]) -> String? {
    attributes[localName] ?? attributes.first { $0.key.hasSuffix(":" + localName) }?.value
}
