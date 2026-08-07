import Foundation

enum ODSWorkbookParser {
    static func parse(_ xml: Data) throws -> SpreadsheetWorkbook {
        let delegate = ContentDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure ?? parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        guard !delegate.workbook.sheets.isEmpty else {
            throw ParserError("content.xml contains no spreadsheet sheets")
        }
        return delegate.workbook
    }

    private final class ContentDelegate: NSObject, XMLParserDelegate {
        var workbook = SpreadsheetWorkbook(sheets: [])
        var failure: Error?

        private var currentSheetName: String?
        private var currentRows = [[SpreadsheetCell]]()
        private var currentRow: [SpreadsheetCell]?
        private var currentRowRepeat = 1
        private var pendingEmptyCells = 0
        private var pendingEmptyRows = 0
        private var currentCell: CellBuilder?
        private var capturesCellText = false
        private var paragraphCount = 0
        private var expandedCellCount = 0
        private var tableDepth = 0
        private var sawRoot = false
        /// Wahr, solange der Parser im Container
        /// `office:document-content/office:body/office:spreadsheet` steht. Nur
        /// dort ist ein `table:table` wirklich ein Arbeitsblatt; in einem
        /// `office:text` wäre es eine Textabelle.
        private var isInSpreadsheetBody = false
        private var bodyDepth = 0

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
                guard namespaceURI == Namespaces.office,
                      elementName == "document-content" else {
                    return fail("content.xml has no valid OpenDocument content root", parser: parser)
                }
                return
            }
            if namespaceURI == Namespaces.office, elementName == "body" {
                bodyDepth += 1
                return
            }
            if namespaceURI == Namespaces.office, elementName == "spreadsheet", bodyDepth == 1 {
                isInSpreadsheetBody = true
                return
            }
            guard isInSpreadsheetBody else { return }

            if namespaceURI == Namespaces.table, elementName == "table" {
                guard currentSheetName == nil else {
                    tableDepth += 1
                    workbook.hasUnsupportedObjects = true
                    return
                }
                guard workbook.sheets.count < Limits.maximumSheets else {
                    return fail("the workbook contains too many sheets", parser: parser)
                }
                tableDepth = 1
                currentSheetName = attribute("name", in: attributeDict)
                    ?? "Sheet \(workbook.sheets.count + 1)"
                currentRows = []
                pendingEmptyRows = 0
                return
            }
            guard currentSheetName != nil else { return }
            guard tableDepth == 1 else { return }

            if namespaceURI == Namespaces.table, elementName == "table-row" {
                currentRow = []
                pendingEmptyCells = 0
                currentRowRepeat = positiveRepeat(
                    attribute("number-rows-repeated", in: attributeDict),
                    maximum: Limits.maximumRows,
                    parser: parser
                )
                return
            }

            if namespaceURI == Namespaces.table,
               elementName == "table-cell" || elementName == "covered-table-cell" {
                guard currentRow != nil else { return }
                let repeated = positiveRepeat(
                    attribute("number-columns-repeated", in: attributeDict),
                    maximum: Limits.maximumColumns,
                    parser: parser
                )
                let columnSpan = positiveRepeat(
                    attribute("number-columns-spanned", in: attributeDict),
                    maximum: Limits.maximumColumns,
                    parser: parser
                )
                let rowSpan = positiveRepeat(
                    attribute("number-rows-spanned", in: attributeDict),
                    maximum: Limits.maximumRows,
                    parser: parser
                )
                if columnSpan > 1 || rowSpan > 1 {
                    workbook.hasFlattenedMerges = true
                }
                currentCell = CellBuilder(
                    repeated: repeated,
                    isCovered: elementName == "covered-table-cell",
                    valueType: attribute("value-type", in: attributeDict),
                    rawValue: attribute("value", in: attributeDict)
                        ?? attribute("string-value", in: attributeDict)
                        ?? attribute("date-value", in: attributeDict)
                        ?? attribute("time-value", in: attributeDict)
                        ?? attribute("boolean-value", in: attributeDict),
                    formula: attribute("formula", in: attributeDict)
                )
                paragraphCount = 0
                return
            }

            if namespaceURI == Namespaces.text, elementName == "p", currentCell != nil {
                if paragraphCount > 0 {
                    currentCell?.text.append("\n")
                }
                paragraphCount += 1
                capturesCellText = true
                return
            }
            if namespaceURI == Namespaces.text, elementName == "a", capturesCellText {
                // Der sichtbare Linktext bleibt erhalten, das Linkziel hat im
                // Arbeitsmappenmodell keinen Platz. Das ist ein gemeldeter
                // Verlust, kein stiller.
                workbook.hasUnsupportedObjects = true
            }
            if namespaceURI == Namespaces.text, elementName == "line-break", capturesCellText {
                currentCell?.text.append("\n")
            } else if namespaceURI == Namespaces.text, elementName == "tab", capturesCellText {
                currentCell?.text.append("\t")
            } else if namespaceURI == Namespaces.text, elementName == "s", capturesCellText {
                let count = min(
                    Int(attribute("c", in: attributeDict) ?? "1") ?? 1,
                    Limits.maximumColumns
                )
                currentCell?.text.append(String(repeating: " ", count: max(1, count)))
            }

            if namespaceURI == Namespaces.drawing || namespaceURI == Namespaces.chart
                || namespaceURI == Namespaces.office && elementName == "annotation" {
                workbook.hasUnsupportedObjects = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if tableDepth == 1, capturesCellText {
                currentCell?.text.append(string)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard failure == nil else { return }
            if namespaceURI == Namespaces.office, elementName == "spreadsheet" {
                isInSpreadsheetBody = false
                return
            }
            if namespaceURI == Namespaces.office, elementName == "body" {
                bodyDepth -= 1
                return
            }
            guard isInSpreadsheetBody else { return }
            if namespaceURI == Namespaces.table, elementName == "table" {
                if tableDepth > 1 {
                    tableDepth -= 1
                    return
                }
                if tableDepth == 1, let name = currentSheetName {
                    workbook.sheets.append(SpreadsheetSheet(name: name, rows: currentRows))
                    currentSheetName = nil
                    currentRows = []
                    pendingEmptyRows = 0
                    tableDepth = 0
                }
                return
            }
            guard tableDepth == 1 else { return }
            if namespaceURI == Namespaces.text, elementName == "p" {
                capturesCellText = false
                return
            }
            if namespaceURI == Namespaces.table,
               elementName == "table-cell" || elementName == "covered-table-cell" {
                finishCell(parser: parser)
                return
            }
            if namespaceURI == Namespaces.table, elementName == "table-row" {
                finishRow(parser: parser)
                return
            }
        }

        private func finishCell(parser: XMLParser) {
            guard let builder = currentCell, currentRow != nil else { return }
            defer { currentCell = nil }
            let cell = builder.cell
            if builder.formula != nil, cell.displayText.isEmpty {
                workbook.hasFormulaWithoutResult = true
            }
            if builder.isCovered {
                flushPendingCells(parser: parser)
                guard failure == nil,
                      currentRow!.count + builder.repeated <= Limits.maximumColumns else {
                    return fail("a spreadsheet row exceeds the column budget", parser: parser)
                }
                currentRow!.append(contentsOf: repeatElement(.empty, count: builder.repeated))
                expandedCellCount += builder.repeated
                checkCellBudget(parser: parser)
                return
            }
            if cell.isEmpty {
                pendingEmptyCells += builder.repeated
                guard currentRow!.count + pendingEmptyCells <= Limits.maximumColumns else {
                    return fail("a spreadsheet row exceeds the column budget", parser: parser)
                }
                return
            }
            flushPendingCells(parser: parser)
            guard failure == nil else { return }
            guard currentRow!.count + builder.repeated <= Limits.maximumColumns else {
                return fail("a spreadsheet row exceeds the column budget", parser: parser)
            }
            currentRow!.append(contentsOf: repeatElement(cell, count: builder.repeated))
            expandedCellCount += builder.repeated
            checkCellBudget(parser: parser)
        }

        private func flushPendingCells(parser: XMLParser) {
            guard pendingEmptyCells > 0 else { return }
            guard currentRow!.count + pendingEmptyCells <= Limits.maximumColumns else {
                return fail("a spreadsheet row exceeds the column budget", parser: parser)
            }
            currentRow!.append(contentsOf: repeatElement(.empty, count: pendingEmptyCells))
            expandedCellCount += pendingEmptyCells
            pendingEmptyCells = 0
            checkCellBudget(parser: parser)
        }

        private func finishRow(parser: XMLParser) {
            guard let row = currentRow else { return }
            defer { currentRow = nil }
            // Ausgedehnte leere Randzellen werden absichtlich nicht materialisiert.
            pendingEmptyCells = 0
            if row.isEmpty {
                pendingEmptyRows += currentRowRepeat
                guard pendingEmptyRows <= Limits.maximumRows else {
                    return fail("a spreadsheet sheet exceeds the row budget", parser: parser)
                }
                return
            }
            if pendingEmptyRows > 0 {
                guard currentRows.count + pendingEmptyRows <= Limits.maximumRows else {
                    return fail("a spreadsheet sheet exceeds the row budget", parser: parser)
                }
                currentRows.append(contentsOf: repeatElement([], count: pendingEmptyRows))
                pendingEmptyRows = 0
            }
            guard currentRows.count + currentRowRepeat <= Limits.maximumRows else {
                return fail("a spreadsheet sheet exceeds the row budget", parser: parser)
            }
            let repeatedCellCount = row.count * max(0, currentRowRepeat - 1)
            guard expandedCellCount <= Limits.maximumCells - repeatedCellCount else {
                return fail("the spreadsheet exceeds the expanded-cell budget", parser: parser)
            }
            currentRows.append(contentsOf: repeatElement(row, count: currentRowRepeat))
            expandedCellCount += repeatedCellCount
        }

        private func positiveRepeat(
            _ text: String?,
            maximum: Int,
            parser: XMLParser
        ) -> Int {
            guard let text else { return 1 }
            guard let value = Int(text), value > 0, value <= maximum else {
                fail("a repeated row or column count exceeds its budget", parser: parser)
                return 1
            }
            return value
        }

        private func checkCellBudget(parser: XMLParser) {
            if expandedCellCount > Limits.maximumCells {
                fail("the spreadsheet exceeds the expanded-cell budget", parser: parser)
            }
        }

        private func fail(_ reason: String, parser: XMLParser) {
            guard failure == nil else { return }
            failure = ParserError(reason)
            parser.abortParsing()
        }
    }

    private struct CellBuilder {
        let repeated: Int
        let isCovered: Bool
        let valueType: String?
        let rawValue: String?
        let formula: String?
        var text = ""

        var cell: SpreadsheetCell {
            let display = text.isEmpty ? (rawValue ?? "") : text
            let value: SpreadsheetCellValue = switch valueType {
            case "float", "currency", "percentage": .number(rawValue ?? display)
            case "boolean": .boolean((rawValue ?? display).lowercased() == "true")
            case "date", "time": .date(rawValue ?? display)
            case "string": .string(display)
            default: display.isEmpty ? .empty : .string(display)
            }
            return SpreadsheetCell(value: value, displayText: display, formula: formula)
        }
    }

    private enum Limits {
        static let maximumSheets = 256
        static let maximumRows = 100_000
        static let maximumColumns = 16_384
        static let maximumCells = 1_000_000
    }

    private enum Namespaces {
        static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
        static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
        static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
        static let drawing = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
        static let chart = "urn:oasis:names:tc:opendocument:xmlns:chart:1.0"
    }

    private struct ParserError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

private func attribute(_ localName: String, in attributes: [String: String]) -> String? {
    attributes[localName] ?? attributes.first { $0.key.hasSuffix(":" + localName) }?.value
}
