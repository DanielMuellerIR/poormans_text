import Foundation

struct XLSXNumberStyles: Sendable {
    private let formats: [SpreadsheetNumberFormat]

    init() { formats = [SpreadsheetNumberFormat(code: "General")] }

    init(_ xml: Data) throws {
        guard xml.count <= 16 * 1_024 * 1_024 else { throw StylesError("the XLSX styles exceed the 16 MiB XML limit") }
        let delegate = StylesDelegate()
        let parser = ImportXMLParser.make(xml, delegate: delegate)
        let success = parser.parse()
        try ConversionExecution.check()
        guard success, delegate.failure == nil, delegate.hasValidRoot else {
            throw StylesError(delegate.failure ?? parser.parserError?.localizedDescription ?? "the XLSX styles part is invalid")
        }
        var compiled: [Int: SpreadsheetNumberFormat] = [:]
        formats = delegate.cellStyles.map { style in
            if let base = style.base, !delegate.baseStyles.indices.contains(base),
               style.apply == false || style.numberFormat == nil {
                return SpreadsheetNumberFormat(unsupported: "the cell's inherited number style has no valid definition")
            }
            let inherited = style.base.flatMap { delegate.baseStyles.indices.contains($0) ? delegate.baseStyles[$0].numberFormat : nil }
            let id = style.apply == false ? (inherited ?? 0) : style.numberFormat ?? inherited ?? 0
            if let format = compiled[id] { return format }
            let format: SpreadsheetNumberFormat
            if let code = delegate.codes[id] ?? SpreadsheetNumberFormat.builtInCode(id) {
                format = SpreadsheetNumberFormat(code: code)
            } else { format = SpreadsheetNumberFormat(unsupported: "number format ID \(id) has no supported definition") }
            compiled[id] = format
            return format
        }
    }

    func format(_ value: String, style: Int, dateSystem: SpreadsheetDateSystem) -> SpreadsheetFormattedNumber {
        guard formats.indices.contains(style) else {
            return .init(text: value, issue: "cell style index \(style) has no valid definition")
        }
        return formats[style].format(value, dateSystem: dateSystem)
    }

    private struct Style {
        let numberFormat: Int?
        let base: Int?
        let apply: Bool?
    }

    private final class StylesDelegate: NSObject, XMLParserDelegate {
        var codes: [Int: String] = [:]
        var cellStyles: [Style] = []
        var baseStyles: [Style] = []
        var failure: String?
        var hasValidRoot = false
        private var stack: [String] = []
        private var codeBytes = 0
        private var nodes = 0
        private var attributeCount = 0
        private static let namespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            nodes += 1
            attributeCount += attributes.count
            guard nodes <= 200_000, attributeCount <= 200_000, stack.count < 128 else {
                return fail("the XLSX styles exceed XML node, attribute or depth limits", parser)
            }
            let parent = stack.last
            stack.append(namespaceURI == Self.namespace ? name : "")
            if stack.count == 1 { hasValidRoot = name == "styleSheet" && namespaceURI == Self.namespace }
            guard failure == nil, namespaceURI == Self.namespace else { return }
            if name == "numFmt", parent == "numFmts", stack.count == 3 {
                guard let rawID = attributes["numFmtId"], let id = Int(rawID), (0...65_535).contains(id),
                      let code = attributes["formatCode"], codes[id] == nil,
                      codes.count < 65_536, code.utf8.count <= 16_384,
                      codeBytes <= 1_048_576 - code.utf8.count else {
                    return fail("the XLSX number-format definitions are invalid, duplicated or exceed their budget", parser)
                }
                codes[id] = code
                codeBytes += code.utf8.count
            } else if name == "xf", stack.count == 3, parent == "cellXfs" || parent == "cellStyleXfs" {
                let id = attributes["numFmtId"].map { Int($0) ?? -1 }
                let base = attributes["xfId"].map { Int($0) ?? -1 }
                let rawApply = attributes["applyNumberFormat"]
                guard id.map({ (0...65_535).contains($0) }) ?? true,
                      base.map({ (0...65_535).contains($0) }) ?? true,
                      rawApply.map({ ["0", "1", "true", "false"].contains($0) }) ?? true,
                      cellStyles.count + baseStyles.count < 65_536 else {
                    return fail("an XLSX number style is invalid or exceeds the style budget", parser)
                }
                let style = Style(numberFormat: id, base: base, apply: rawApply.map { $0 == "1" || $0 == "true" })
                if parent == "cellXfs" { cellStyles.append(style) } else { baseStyles.append(style) }
            }
        }

        func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            if !stack.isEmpty { stack.removeLast() }
        }

        private func fail(_ message: String, _ parser: XMLParser) { failure = message; parser.abortParsing() }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) {
            fail("entity declarations are not allowed in XLSX styles", parser)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) {
            fail("entity declarations are not allowed in XLSX styles", parser)
        }
    }

    private struct StylesError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}
