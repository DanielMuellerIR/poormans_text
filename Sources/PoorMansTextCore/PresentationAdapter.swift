import Foundation

struct PresentationAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors = [
        SupportedFormat(format: .pptx, fileExtensions: ["pptx", "pptm", "potx"], containerKind: .file, requiredTools: []),
        SupportedFormat(format: .odp, fileExtensions: ["odp"], containerKind: .file, requiredTools: [])
    ]
    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let claimed: InputFormat? = ["pptx", "pptm", "potx"].contains(inputURL.pathExtension.lowercased()) ? .pptx : inputURL.pathExtension.lowercased() == "odp" ? .odp : nil
        do {
            let prefix = try VerifiedFileStaging.prefix(of: inputURL, maximumBytes: 1_073_741_824, prefixBytes: 4, describedAs: "the presentation source")
            guard prefix.starts(with: [0x50, 0x4B]) else {
                if let claimed { return .invalid(format: claimed, priority: 115, reason: "the presentation ZIP signature is missing") }
                return .noMatch
            }
            let reader = try ZIPArchiveInspector.inspectionSnapshot(at: inputURL)
            guard let format = try format(reader) else { return .noMatch }
            return .match(AdapterInputInspection(format: format, priority: 115, expectedWarnings: [ConversionWarning(code: "presentation.layoutNotPreserved", message: "Slide positions, themes, transitions, animations and exact formatting are not preserved.")] + (reader.entryNames.contains(where: { $0.hasSuffix("vbaProject.bin") }) ? [ConversionWarning(code: "presentation.macrosNotPreserved", message: "Presentation macros are never executed and are not copied.")] : [])))
        } catch {
            try ConversionExecution.check()
            return claimed.map { .invalid(format: $0, priority: 115, reason: error.localizedDescription) } ?? .noMatch
        }
    }
    private func format(_ reader: any ZIPPackageReading) throws -> InputFormat? {
        if reader.entryNames.contains("ppt/presentation.xml") {
            let root = try ImportXML.parse(reader.data(named: "ppt/presentation.xml"))
            guard root.name == "presentation", root.namespace == PresentationImport.presentation else { throw ImportFailure("invalid presentation root") }
            let types = try ImportXML.parse(reader.data(named: "[Content_Types].xml"))
            let accepted = ["application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml", "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml", "application/vnd.openxmlformats-officedocument.presentationml.template.main+xml"]
            guard types.name == "Types", types.namespace == "http://schemas.openxmlformats.org/package/2006/content-types", types.children.contains(where: { $0.name == "Override" && $0.namespace == types.namespace && $0.attribute("PartName") == "/ppt/presentation.xml" && accepted.contains($0.attribute("ContentType") ?? "") }) else { throw ImportFailure("unsupported presentation content type") }
            return .pptx
        }
        if try reader.dataIfPresent(named: "mimetype").map({ String(decoding: $0, as: UTF8.self) }) == "application/vnd.oasis.opendocument.presentation" {
            let root = try ImportXML.parse(reader.data(named: "content.xml"))
            let pages = root.elements("body", namespace: PresentationImport.office).flatMap { $0.elements("presentation", namespace: PresentationImport.office) }.flatMap { $0.elements("page", namespace: PresentationImport.draw) }
            guard root.name == "document-content", root.namespace == PresentationImport.office, !pages.isEmpty, pages.count <= 1_000 else { throw ImportFailure("invalid OpenDocument presentation content or slide count") }
            return .odp
        }
        return nil
    }
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        do {
            let reader = try ZIPArchiveInspector.openVerifiedPackage(from: context.resolvedInputURL, into: context.workDirectory, named: "presentation.zip")
            guard try format(reader) == context.format else { throw ImportFailure("presentation format changed after inspection") }
            let importer = PresentationImport(reader: reader, output: context.stagedOutputDirectory)
            let markdown = try importer.convert(format: context.format, title: context.inputURL.deletingPathExtension().lastPathComponent)
            let filename = context.inputURL.deletingPathExtension().lastPathComponent + ".md"
            try Data(markdown.utf8).write(to: context.stagedOutputDirectory.appendingPathComponent(filename), options: .atomic)
            return StagedConversionResult(markdownRelativePath: filename, assetRelativePaths: importer.media.paths, warnings: importer.diagnostics.result, metadata: PackageMetadataParser.read(from: reader, entryName: context.format == .pptx ? "docProps/core.xml" : "meta.xml"))
        } catch {
            try ConversionExecution.check()
            throw ConversionError.invalidInput(context.inputURL, format: context.format, reason: error.localizedDescription)
        }
    }
}

/// Paketpfade werden innerhalb des Archivs aufgelöst, niemals auf der Quelle.
enum ImportPackagePath {
    static func resolve(_ target: String, relativeTo part: String) throws -> String {
        guard let decoded = target.removingPercentEncoding, !decoded.isEmpty,
              !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains(":"),
              !decoded.contains("?"), !decoded.contains("#"), !decoded.unicodeScalars.contains(where: { $0.value < 32 }) else { throw ImportFailure("unsafe or external package reference: \(target)") }
        var components = part.split(separator: "/").dropLast().map(String.init)
        for component in decoded.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { guard !components.isEmpty else { throw ImportFailure("package reference escapes the archive") }; components.removeLast() }
            else { components.append(String(component)) }
        }
        guard !components.isEmpty else { throw ImportFailure("empty package reference") }
        return components.joined(separator: "/")
    }
}

final class PresentationImport {
    static let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let drawing = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let relations = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    static let draw = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
    static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    static let xlink = "http://www.w3.org/1999/xlink"
    let reader: any ZIPPackageReading
    let media: ImportMediaStore
    var diagnostics = ImportDiagnostics()
    private var page = 0
    private var expandedTextBytes = 0
    private var listStyles: [String: [Int: Bool]] = [:]
    init(reader: any ZIPPackageReading, output: URL) { self.reader = reader; media = ImportMediaStore(output: output) }
    private struct Relation { let type: String; let target: String; let external: Bool }
    private func relationships(for part: String) throws -> [String: Relation] {
        let url = part as NSString
        let path = (url.deletingLastPathComponent as NSString).appendingPathComponent("_rels/" + url.lastPathComponent + ".rels")
        guard let data = try reader.dataIfPresent(named: path) else { return [:] }
        let root = try ImportXML.parse(data)
        guard root.name == "Relationships", root.namespace == "http://schemas.openxmlformats.org/package/2006/relationships" else { throw ImportFailure("invalid relationship root") }
        var result: [String: Relation] = [:]
        for node in root.children {
            guard let id = node.attribute("Id"), let target = node.attribute("Target"), let type = node.attribute("Type"), result[id] == nil else { throw ImportFailure("invalid or duplicate package relationship") }
            result[id] = Relation(type: type, target: target, external: node.attribute("TargetMode") == "External")
        }
        return result
    }
    func convert(format: InputFormat, title: String) throws -> String {
        diagnostics.add("presentation.layoutNotPreserved", "Slide positions, themes, transitions, animations and exact formatting are not preserved.")
        if reader.entryNames.contains(where: { $0.hasSuffix("vbaProject.bin") }) { diagnostics.add("presentation.macrosNotPreserved", "Presentation macros are never executed and are not copied.") }
        var markdown = "# " + MarkdownEscaping.heading(title) + "\n\n"
        func append(_ text: String) throws {
            guard markdown.utf8.count <= 128 * 1_024 * 1_024 - text.utf8.count else { throw ImportFailure("presentation Markdown exceeds 128 MiB") }
            markdown += text
        }
        if format == .pptx {
            let part = "ppt/presentation.xml"
            let root = try ImportXML.parse(reader.data(named: part))
            let relations = try relationships(for: part)
            let ids = root.elements("sldIdLst", namespace: Self.presentation).flatMap { $0.elements("sldId", namespace: Self.presentation) }
            guard !ids.isEmpty, ids.count <= 1_000 else { throw ImportFailure("presentation requires between 1 and 1,000 slides") }
            for (index, id) in ids.enumerated() {
                page = index + 1
                try ConversionExecution.report(unit: .slide, completed: index, total: ids.count)
                guard let key = id.attribute("id", namespace: Self.relations), let relation = relations[key], !relation.external, relation.type.hasSuffix("/slide") else { throw ImportFailure("missing or external slide relationship") }
                let path = try ImportPackagePath.resolve(relation.target, relativeTo: part)
                let slide = try autoreleasepool { try pptxSlide(path) }
                try append(PresentationRenderer.render(slide, number: page, maximumBytes: 128 * 1_024 * 1_024 - markdown.utf8.count))
            }
            try ConversionExecution.report(unit: .slide, completed: ids.count, total: ids.count)
        } else {
            let root = try ImportXML.parse(reader.data(named: "content.xml"))
            if let data = try reader.dataIfPresent(named: "styles.xml") { collectListStyles(try ImportXML.parse(data)) }
            collectListStyles(root)
            guard root.name == "document-content", root.namespace == Self.office else { throw ImportFailure("invalid OpenDocument presentation root") }
            let slides = root.elements("body", namespace: Self.office).flatMap { $0.elements("presentation", namespace: Self.office) }.flatMap { $0.elements("page", namespace: Self.draw) }
            guard !slides.isEmpty, slides.count <= 1_000 else { throw ImportFailure("presentation requires between 1 and 1,000 slides") }
            for (index, node) in slides.enumerated() {
                page = index + 1
                try ConversionExecution.report(unit: .slide, completed: index, total: slides.count)
                var slide = PresentationSlide()
                for child in node.children {
                    if child.name == "notes", child.namespace == Self.presentationODF { slide.notes += try odpBlocks(child, level: nil) }
                    else { slide.blocks += try odpBlocks(child, level: nil) }
                }
                try append(PresentationRenderer.render(slide, number: page, maximumBytes: 128 * 1_024 * 1_024 - markdown.utf8.count))
            }
            try ConversionExecution.report(unit: .slide, completed: slides.count, total: slides.count)
        }
        return markdown
    }
    static let presentationODF = "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"
    private func pptxSlide(_ part: String) throws -> PresentationSlide {
        let root = try ImportXML.parse(reader.data(named: part))
        guard root.name == "sld", root.namespace == Self.presentation else { throw ImportFailure("invalid slide root at \(part)") }
        let relations = try relationships(for: part)
        var result = PresentationSlide(blocks: try pptxBlocks(root, part: part, relations: relations))
        for relation in relations.values where relation.type.hasSuffix("/notesSlide") {
            guard !relation.external else { diagnostics.add("presentation.notesUnavailable", "External notes were not loaded.", page: page); continue }
            let path = try ImportPackagePath.resolve(relation.target, relativeTo: part)
            guard let data = try reader.dataIfPresent(named: path) else { diagnostics.add("presentation.notesUnavailable", "A notes part is missing: \(path)", page: page); continue }
            result.notes += try pptxBlocks(ImportXML.parse(data), part: path, relations: relationships(for: path))
        }
        return result
    }
    private func pptxBlocks(_ node: ImportXML, part: String, relations: [String: Relation]) throws -> [PresentationBlock] {
        try ConversionExecution.check()
        if node.name == "sp", node.namespace == Self.presentation,
           !node.descendants("ph", namespace: Self.presentation).isEmpty,
           node.descendants("p", namespace: Self.drawing).contains(where: { $0.elements("pPr", namespace: Self.drawing).isEmpty }) {
            diagnostics.add("presentation.inheritedListStyleNotPreserved", "Layout/master list formatting is not reconstructed; all paragraph text is retained.", page: page)
        }
        if node.name == "p", node.namespace == Self.drawing {
            if !node.descendants("hlinkClick", namespace: Self.drawing).isEmpty { diagnostics.add("presentation.hyperlinkFlattened", "A text hyperlink was preserved as visible text only.", page: page) }
            let text = drawingText(node)
            guard !text.isEmpty else { return [] }
            let properties = node.elements("pPr", namespace: Self.drawing).first
            let noBullet = properties?.elements("buNone", namespace: Self.drawing).isEmpty == false
            let hasBullet = properties?.attribute("lvl") != nil || properties?.children.contains(where: { ["buChar", "buAutoNum"].contains($0.name) }) == true
            let level = noBullet || !hasBullet ? nil : Int(properties?.attribute("lvl") ?? "0") ?? 0
            return [.paragraph(text, level: level, ordered: properties?.elements("buAutoNum", namespace: Self.drawing).isEmpty == false)]
        }
        if node.name == "tbl", node.namespace == Self.drawing {
            let rows = node.elements("tr", namespace: Self.drawing).map { row in row.elements("tc", namespace: Self.drawing).map { $0.descendants("p", namespace: Self.drawing).map(drawingText).joined(separator: "\n") } }
            if node.descendants("tc", namespace: Self.drawing).contains(where: { $0.attribute("gridSpan") != nil || $0.attribute("rowSpan") != nil }) { diagnostics.add("presentation.tableMergesFlattened", "Merged table cells were flattened.", page: page) }
            return [.table(rows)]
        }
        if node.name == "blip", node.namespace == Self.drawing {
            guard let id = node.attribute("embed", namespace: Self.relations) ?? node.attribute("link", namespace: Self.relations), let relation = relations[id], relation.type.hasSuffix("/image"), !relation.external else {
                diagnostics.add("presentation.imageUnavailable", "An external or missing image relationship was not loaded.", page: page); return []
            }
            return try packageImage(relation.target, part: part)
        }
        if node.namespace == Self.presentation, node.name == "sp",
           node.descendants("ph", namespace: Self.presentation).contains(where: { ["sldImg", "sldNum", "hdr", "ftr", "dt"].contains($0.attribute("type") ?? "") }) { return [] }
        if ["chart", "relIds", "oleObj", "videoFile", "audioFile", "contentPart"].contains(node.name) { diagnostics.add("presentation.objectNotRepresented", "A \(node.name) object is not represented as Markdown.", page: page) }
        return try node.children.flatMap { try pptxBlocks($0, part: part, relations: relations) }
    }
    private func drawingText(_ node: ImportXML) -> String {
        if node.namespace == Self.drawing {
            if node.name == "t" { return node.text }
            if node.name == "br" { return "\n" }
            if node.name == "tab" { return "\t" }
        }
        return node.children.map(drawingText).joined()
    }
    private func packageImage(_ target: String, part: String) throws -> [PresentationBlock] {
        do {
            let path = try ImportPackagePath.resolve(target, relativeTo: part)
            let stored = try media.save(reader.data(named: path))
            return [.image(stored, "Slide image")]
        } catch {
            try ConversionExecution.check()
            diagnostics.add("presentation.imageUnavailable", "Image \(target) was not copied: \(error.localizedDescription)", page: page)
            return []
        }
    }
    private func odpBlocks(_ node: ImportXML, level: Int?, listStyle: String? = nil) throws -> [PresentationBlock] {
        try ConversionExecution.check()
        if node.namespace == Self.text {
            if node.name == "p" || node.name == "h" { return [.paragraph(try odfText(node), level: level, ordered: listStyle.flatMap { listStyles[$0]?[(level ?? 0) + 1] } ?? false)] }
            if node.name == "list" {
                let style = node.attribute("style-name", namespace: Self.text) ?? listStyle
                if let style, listStyles[style] == nil { diagnostics.add("presentation.listStyleNotPreserved", "An unavailable list style was rendered as bullets: \(style)", page: page) }
                return try node.children.flatMap { try odpBlocks($0, level: (level ?? -1) + 1, listStyle: style) }
            }
        }
        if node.namespace == Self.table, node.name == "table" {
            var rows: [[String]] = []
            var expandedBytes = 0
            for row in tableRows(node) {
                var cells: [String] = []
                var rowBytes = 3
                for cell in row.children where cell.namespace == Self.table && ["table-cell", "covered-table-cell"].contains(cell.name) {
                    let count = try repeatCount(cell.attribute("number-columns-repeated", namespace: Self.table), maximum: 256)
                    var text = try cell.descendants("p", namespace: Self.text).map(odfText).joined(separator: "\n")
                    if text.isEmpty { text = cell.attribute("string-value", namespace: Self.office) ?? cell.attribute("value", namespace: Self.office) ?? cell.attribute("date-value", namespace: Self.office) ?? cell.attribute("boolean-value", namespace: Self.office) ?? cell.attribute("time-value", namespace: Self.office) ?? "" }
                    // UTF-8-Zeichen können beim Maskieren höchstens verdoppeln;
                    // ein Zeilenwechsel wird zu vier Bytes (<br>).
                    let cellBytes = text.utf8.count * 4 + 3
                    guard cellBytes <= (128 * 1_024 * 1_024 - rowBytes) / count else { throw ImportFailure("expanded presentation table exceeds its output budget") }
                    rowBytes += cellBytes * count
                    if !cell.descendants("table", namespace: Self.table).isEmpty { diagnostics.add("presentation.nestedTableFlattened", "A nested table was flattened into cell text.", page: page) }
                    guard cells.count <= 256 - count else { throw ImportFailure("presentation table exceeds 256 columns") }
                    cells += Array(repeating: text, count: count)
                    if cell.attribute("number-columns-spanned", namespace: Self.table) != nil || cell.attribute("number-rows-spanned", namespace: Self.table) != nil { diagnostics.add("presentation.tableMergesFlattened", "Merged table cells were flattened.", page: page) }
                }
                let count = try repeatCount(row.attribute("number-rows-repeated", namespace: Self.table), maximum: 1_000)
                guard rows.count <= 1_000 - count else { throw ImportFailure("presentation table exceeds 1,000 rows") }
                guard rowBytes <= (128 * 1_024 * 1_024 - expandedBytes) / count else { throw ImportFailure("expanded presentation table exceeds its output budget") }
                expandedBytes += rowBytes * count
                rows += Array(repeating: cells, count: count)
            }
            return [.table(rows)]
        }
        if node.namespace == Self.draw, node.name == "image" {
            guard let target = node.attribute("href", namespace: Self.xlink) else { diagnostics.add("presentation.imageUnavailable", "An image has no local reference.", page: page); return [] }
            return try packageImage(target, part: "content.xml")
        }
        if node.namespace == Self.draw, ["object", "object-ole", "plugin", "applet"].contains(node.name) { diagnostics.add("presentation.objectNotRepresented", "An embedded \(node.name) object is not represented as Markdown.", page: page) }
        return try node.children.flatMap { try odpBlocks($0, level: level, listStyle: listStyle) }
    }
    private func tableRows(_ node: ImportXML) -> [ImportXML] {
        node.children.flatMap { child -> [ImportXML] in
            guard child.namespace == Self.table else { return [] }
            if child.name == "table-row" { return [child] }
            if ["table-header-rows", "table-rows", "table-row-group"].contains(child.name) { return tableRows(child) }
            return []
        }
    }

    private func collectListStyles(_ root: ImportXML) {
        for style in root.descendants("list-style", namespace: Self.text) {
            guard let name = style.attribute("name", namespace: "urn:oasis:names:tc:opendocument:xmlns:style:1.0") else { continue }
            for level in style.children where level.namespace == Self.text {
                if let number = Int(level.attribute("level", namespace: Self.text) ?? ""), (1...16).contains(number) {
                    listStyles[name, default: [:]][number] = level.name == "list-level-style-number"
                }
            }
        }
    }

    private func repeatCount(_ value: String?, maximum: Int) throws -> Int {
        guard let count = Int(value ?? "1"), count > 0, count <= maximum else { throw ImportFailure("invalid presentation table repetition") }
        return count
    }
    private func odfText(_ node: ImportXML) throws -> String {
        var output = ImportTextBuilder(maximumBytes: min(16 * 1_024 * 1_024, 128 * 1_024 * 1_024 - expandedTextBytes))
        try appendODFText(node, to: &output)
        expandedTextBytes += output.bytes
        return output.value
    }
    private func appendODFText(_ node: ImportXML, to output: inout ImportTextBuilder) throws {
        try ConversionExecution.check()
        if node.namespace == Self.text {
            if node.name == "a", node.attribute("href", namespace: Self.xlink) != nil { diagnostics.add("presentation.hyperlinkFlattened", "A text hyperlink was preserved as visible text only; its target was not loaded.", page: page) }
            if node.name == "s" {
                let count = try repeatCount(node.attribute("c", namespace: Self.text), maximum: 4_096)
                guard count <= output.maximumBytes - output.bytes else { throw ImportFailure("expanded presentation text exceeds its output budget") }
                try output.append(String(repeating: " ", count: count)); return
            }
            if node.name == "tab" { try output.append("\t"); return }
            if node.name == "line-break" { try output.append("\n"); return }
        }
        for content in node.content {
            switch content {
            case .text(let text): try output.append(text)
            case .element(let child): try appendODFText(child, to: &output)
            }
        }
    }
}
