import Foundation
import PDFKit

final class PDFAnnotations {
    struct Mapping {
        let location: ConversionLocation
        let offset: Int
        let length: Int
    }
    struct Page {
        let markdown: String
        let mappings: [Mapping]
    }
    private struct Entry {
        let number: Int
        let location: ConversionLocation
        let type: String
        let metadata: String
        let contents: String
        let target: String?
        let keepsDetails: Bool
        var bound = false
    }
    private struct Replacement {
        let entry: Int
        let range: Range<String.Index>
        let label: String
        let target: String
    }
    private let document: PDFDocument
    private let selectedPages: Set<Int>
    private var diagnostics = BoundedConversionDiagnostics()
    private var annotationCount = 0
    private var annotationBytes = 0
    private var appendixBytes = 0
    private var geometryCount = 0
    private var searchBytes = 0
    let hasAnnotations: Bool
    var warnings: [ConversionWarning] { diagnostics.result }

    init(document: PDFDocument, selectedPages: Set<Int>) {
        self.document = document
        self.selectedPages = selectedPages
        hasAnnotations = selectedPages.contains { document.page(at: $0 - 1)?.annotations.isEmpty == false }
    }

    func render(_ markdown: String, pageNumber: Int) throws -> Page {
        guard let page = document.page(at: pageNumber - 1) else { throw ImportFailure("an annotated PDF page is missing") }
        let annotations = page.annotations
        guard !annotations.isEmpty else { return .init(markdown: markdown, mappings: []) }
        guard annotations.count <= 8_192 - annotationCount else { throw ImportFailure("PDF exceeds 8192 annotations") }
        let sourceText = page.string ?? ""
        var entries: [Entry] = []
        var replacements: [Replacement] = []
        let rawObjects = rawAnnotations(page: page, annotations: annotations)
        if rawObjects == nil {
            warn("pdf.annotationRawValuesUnavailable", "PDF annotation objects could not be aligned safely with their raw source values; only readable PDFKit metadata and plain text were retained.", .init(page: pageNumber), kind: .contentLoss)
        }
        let ignoredPopups = try associatedPopups(objects: rawObjects, annotations: annotations)
        for (index, annotation) in annotations.enumerated() {
            try ConversionExecution.check()
            guard annotationCount < 8_192 else { throw ImportFailure("PDF exceeds 8192 annotations") }
            annotationCount += 1
            if ignoredPopups.contains(index) { continue }
            let number = index + 1
            let location = ConversionLocation(page: pageNumber, note: "Annotation \(number)")
            let type = annotation.type ?? "Unknown"
            guard type.utf8.count <= 1_024 else { throw ImportFailure("a PDF annotation type exceeds its metadata limit") }
            let rawObject = rawObjects?[index]
            // PDFKit kann /RC beim Lesen bereits zu Text umformen. Rohwerte
            // verhindern eine unbemerkte HTML-Auswertung in dieser Stufe.
            let plain = try rawObject.map { try rawText($0, key: "Contents") ?? "" } ?? (annotation.value(forAnnotationKey: .contents) as? String) ?? ""
            let rich = try rawObject.map { try rawText($0, key: "RC") } ?? (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/RC")) as? String)
            let contents = plain.isEmpty ? rich ?? "" : plain
            if plain.isEmpty, rich?.isEmpty == false {
                warn("pdf.annotationRichTextLiteral", "The annotation contains rich-text source without plain text; it was retained literally without interpreting HTML or loading resources.", location, kind: .contentLoss)
            }
            guard contents.utf8.count <= 1_024 * 1_024 else { throw ImportFailure("a PDF annotation exceeds 1 MiB of text") }
            var fields = ["Type: " + type]
            var keepsDetails = !contents.isEmpty
            func field(_ title: String, _ value: String?) throws {
                if let value, !value.isEmpty {
                    guard value.utf8.count <= 65_536 else { throw ImportFailure("a PDF annotation metadata field exceeds 65536 bytes") }
                    fields.append(title + ": " + value.split(whereSeparator: \.isWhitespace).joined(separator: " ")); keepsDetails = true
                }
            }
            try field("Source annotation ID", try rawObject.map { try rawText($0, key: "NM") } ?? (annotation.value(forAnnotationKey: .name) as? String))
            try field("Author", try rawObject.map { try rawText($0, key: "T") } ?? annotation.userName)
            try field("Created (source)", try rawObject.map { try rawText($0, key: "CreationDate") } ?? dateValue(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/CreationDate"))))
            try field("Modified (source)", try rawObject.map { try rawText($0, key: "M") } ?? dateValue(annotation.value(forAnnotationKey: .date)))
            let labels = try selectedText(annotation, page: page, location: location)
            let excerpt = labels.joined(separator: "\n")
            if excerpt.isEmpty {
                fields.append("Text reference: unavailable; page and annotation geometry retained.")
                warn("pdf.annotationTextUnavailable", "The annotation has no unambiguous embedded-text reference; its available content and page reference were retained.", location)
            } else {
                let limited = excerpt.count > 4_096
                fields.append((limited ? "Source excerpt (first 4096 characters): " : "Source excerpt: ") + String(excerpt.prefix(4_096)))
            }
            let bounds = annotation.bounds
            if valid(bounds) { fields.append("Page rectangle: " + [bounds.minX,bounds.minY,bounds.width,bounds.height].map(coordinate).joined(separator: ", ")) }
            var target: String?
            if type == "Link" {
                let count = fields.count
                target = linkTarget(annotation, location: location, fields: &fields)
                keepsDetails = keepsDetails || fields.count != count
            }
            else if !["Text", "FreeText", "Highlight", "Underline", "StrikeOut", "Squiggly"].contains(type) {
                warn("pdf.annotationTypeNotRepresented", "A \(type) annotation's appearance or behavior was not reconstructed; available text and metadata were retained and page content was not altered.", location, kind: .contentLoss)
            }
            if (type != "Link" && annotation.action != nil) || annotation.value(forAnnotationKey: .additionalActions) != nil {
                warn("pdf.annotationActionNotRepresented", "An annotation action was not executed or converted to an active action.", location, kind: .contentLoss)
            }
            let metadata = fields.joined(separator: "\n")
            try account(metadata.utf8.count + contents.utf8.count + labels.reduce(0) { $0 + $1.utf8.count })
            var entry = Entry(number: number, location: location, type: type, metadata: metadata, contents: contents, target: target, keepsDetails: keepsDetails)
            if let target, !labels.isEmpty {
                var proposals: [Replacement] = []
                for label in labels {
                    guard let range = try matchedRange(label, source: sourceText, markdown: markdown) else { proposals = []; break }
                    proposals.append(.init(entry: entries.count, range: range, label: label, target: target))
                }
                entry.bound = proposals.count == labels.count
                if entry.bound { replacements += proposals }
            }
            entries.append(entry)
        }
        // Überlappende Linkrechtecke werden nicht in eine erfundene Priorität
        // gezwungen. Beide Ziele bleiben als getrennte Anmerkungen erhalten.
        let ordered = replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var conflicts = Set<Int>()
        var active: Replacement?
        for replacement in ordered {
            if let previous = active, replacement.range.lowerBound < previous.range.upperBound {
                conflicts.insert(previous.entry); conflicts.insert(replacement.entry)
            }
            if active == nil || replacement.range.upperBound > active!.range.upperBound { active = replacement }
        }
        for index in conflicts { entries[index].bound = false }
        var output = ImportTextBuilder(maximumBytes: 128 * 1_024 * 1_024)
        var mappings: [Mapping] = []
        var cursor = markdown.startIndex
        for replacement in ordered where entries[replacement.entry].bound {
            try ConversionExecution.check()
            try output.append(String(markdown[cursor..<replacement.range.lowerBound]))
            let text = "[" + MarkdownEscaping.inlineLiteral(replacement.label) + "](" + MarkdownEscaping.linkDestination(replacement.target) + ")"
            let offset = output.bytes; try output.append(text)
            mappings.append(.init(location: entries[replacement.entry].location, offset: offset, length: text.utf8.count))
            cursor = replacement.range.upperBound
        }
        try output.append(String(markdown[cursor...]))
        var headingAdded = false
        for entry in entries {
            try ConversionExecution.check()
            if entry.type == "Link", entry.target != nil {
                if entry.bound {
                    warn("pdf.linkPreserved", "A PDF hyperlink was retained at its unambiguous text range.", entry.location, kind: .information)
                } else {
                    warn("pdf.linkTextUnavailable", "A PDF hyperlink could not be assigned safely to one output text range; its target was retained as a separate page annotation.", entry.location)
                }
            } else {
                warn("pdf.annotationPreserved", "The annotation's available content, author, dates and page/text reference were retained.", entry.location, kind: .information)
            }
            if entry.type == "Link", entry.bound, !entry.keepsDetails { continue }
            if !headingAdded { try output.append("\n\n### Annotations\n"); headingAdded = true }
            var text = "\n#### Annotation \(entry.number)\n\n" + literal(entry.metadata).replacingOccurrences(of: "\n", with: "  \n") + "\n"
            if !entry.contents.isEmpty { text += "\n" + literal(entry.contents) + "\n" }
            if let target = entry.target, !entry.bound { text += "\n[Link annotation \(entry.number)](" + MarkdownEscaping.linkDestination(target) + ")\n" }
            guard text.utf8.count <= 8 * 1_024 * 1_024 - appendixBytes else { throw ImportFailure("PDF annotation output exceeds 8 MiB") }
            appendixBytes += text.utf8.count
            let offset = output.bytes; try output.append(text)
            mappings.append(.init(location: entry.location, offset: offset, length: text.utf8.count))
        }
        return .init(markdown: output.value, mappings: mappings)
    }

    private func selectedText(_ annotation: PDFAnnotation, page: PDFPage, location: ConversionLocation) throws -> [String] {
        let box = page.bounds(for: .mediaBox), bounds = annotation.bounds
        guard valid(box), valid(bounds), box.intersects(bounds) else {
            warn("pdf.annotationGeometryUnavailable", "The annotation has invalid or off-page geometry; its text and page reference were retained separately.", location); return []
        }
        var rectangles = [bounds]
        if let points = annotation.quadrilateralPoints, !points.isEmpty {
            guard points.count.isMultiple(of: 4), points.count <= 4_096 else {
                warn("pdf.annotationGeometryUnavailable", "The annotation has invalid text quadrilaterals; no text range was invented.", location); return []
            }
            rectangles = []
            // PDFKit liefert Quadpunkte relativ zum Annotation-Ursprung,
            // nicht als bereits absolute Seitenkoordinaten.
            for index in stride(from: 0, to: points.count, by: 4) {
                let quad = points[index..<index + 4].map { $0.pointValue }
                guard quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
                let minX = quad.map(\.x).min()!, maxX = quad.map(\.x).max()!
                let minY = quad.map(\.y).min()!, maxY = quad.map(\.y).max()!
                rectangles.append(CGRect(x: bounds.minX + minX, y: bounds.minY + minY, width: maxX - minX, height: maxY - minY))
            }
        }
        guard rectangles.count <= 16_384 - geometryCount else { throw ImportFailure("PDF annotation geometry exceeds 16384 regions") }
        geometryCount += rectangles.count
        var labels: [String] = []
        var selectedBytes = 0
        for rectangle in rectangles {
            try ConversionExecution.check()
            guard valid(rectangle), bounds.insetBy(dx: -1, dy: -1).contains(rectangle), box.intersects(rectangle),
                  let selection = page.selection(for: rectangle) else { continue }
            guard (selection.string?.utf8.count ?? 0) <= 65_536 else { throw ImportFailure("a PDF annotation selects more than 65536 text bytes") }
            for line in selection.selectionsByLine() {
                let lineBounds = line.bounds(for: page)
                guard valid(lineBounds), rectangle.insetBy(dx: -1, dy: -1).contains(lineBounds), let label = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.isEmpty, label.utf8.count <= 65_536 else { continue }
                guard label.utf8.count <= 65_536 - selectedBytes else { throw ImportFailure("a PDF annotation selects more than 65536 text bytes") }
                selectedBytes += label.utf8.count
                labels.append(label)
                guard labels.count <= 1_024 else { throw ImportFailure("a PDF annotation selects more than 1024 text lines") }
            }
        }
        return labels
    }

    private func rawAnnotations(page: PDFPage, annotations: [PDFAnnotation]) -> [CGPDFDictionaryRef]? {
        // PDFKit erzeugt Popup-Wrapper neu und reicht /Parent nicht durch.
        // Auch CGPDF liefert für indirekte Verweise neue Wrapper. Die
        // beidseitigen Verweise müssen deshalb eindeutig zu denselben
        // Rohwerten einer Seitenanmerkung passen; sonst bleibt das Popup.
        var array: CGPDFArrayRef?
        guard let dictionary = page.pageRef?.dictionary,
              CGPDFDictionaryGetArray(dictionary, "Annots", &array), let array,
              CGPDFArrayGetCount(array) == annotations.count else { return nil }
        var objects: [CGPDFDictionaryRef] = []
        for index in annotations.indices {
            var object: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?
            guard CGPDFArrayGetDictionary(array, index, &object), let object,
                  CGPDFDictionaryGetName(object, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == annotations[index].type else { return nil }
            objects.append(object)
        }
        return objects
    }
    private func rawText(_ object: CGPDFDictionaryRef, key: String) throws -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(object, key, &value), let value else { return nil }
        guard CGPDFStringGetLength(value) <= 2 * 1_024 * 1_024 else { throw ImportFailure("a PDF annotation string exceeds 2 MiB") }
        return CGPDFStringCopyTextString(value) as String?
    }
    private func associatedPopups(objects: [CGPDFDictionaryRef]?, annotations: [PDFAnnotation]) throws -> Set<Int> {
        guard let objects, annotations.contains(where: { $0.type == "Popup" }) else { return [] }
        var signatureBytes = 0
        func signature(_ object: CGPDFDictionaryRef) throws -> [String]? {
            var subtype: UnsafePointer<CChar>?, rectangle: CGPDFArrayRef?
            guard CGPDFDictionaryGetName(object, "Subtype", &subtype), let subtype,
                  CGPDFDictionaryGetArray(object, "Rect", &rectangle), let rectangle,
                  CGPDFArrayGetCount(rectangle) == 4 else { return nil }
            var values = [String(cString: subtype)]
            for index in 0..<4 {
                var value: CGPDFReal = 0
                guard CGPDFArrayGetNumber(rectangle, index, &value), value.isFinite else { return nil }
                values.append(String(describing: value))
            }
            for key in ["Contents", "RC", "T", "CreationDate", "M", "NM"] {
                let value = try rawText(object, key: key) ?? ""
                guard value.utf8.count <= 1_024 * 1_024 else { return nil }
                guard value.utf8.count <= 32 * 1_024 * 1_024 - signatureBytes else { throw ImportFailure("PDF popup metadata exceeds 32 MiB") }
                signatureBytes += value.utf8.count
                values.append(value)
            }
            return values
        }
        let signatures = try objects.map(signature)
        var indicesBySignature: [[String]: [Int]] = [:]
        for index in signatures.indices {
            if let signature = signatures[index] { indicesBySignature[signature, default: []].append(index) }
        }
        var ignored = Set<Int>()
        for index in objects.indices where annotations[index].type == "Popup" {
            let object = objects[index]
            var parent: CGPDFDictionaryRef?, reverse: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(object, "Parent", &parent), let parent,
                  let parentSignature = try signature(parent), let popupSignature = signatures[index],
                  CGPDFDictionaryGetDictionary(parent, "Popup", &reverse), let reverse,
                  try signature(reverse) == popupSignature else { continue }
            let matches = indicesBySignature[parentSignature] ?? []
            guard matches.count == 1, annotations[matches[0]].type != "Popup" else { continue }
            let keys = ["Contents", "RC", "T", "CreationDate", "M"]
            if try keys.allSatisfy({ key in
                guard let value = try rawText(object, key: key), !value.isEmpty else { return true }
                return try value == rawText(parent, key: key)
            }) { ignored.insert(index) }
        }
        return ignored
    }

    private func matchedRange(_ label: String, source: String, markdown: String) throws -> Range<String.Index>? {
        var candidates = Set([MarkdownEscaping.inlineLiteral(label), MarkdownEscaping.literalBlock(label)])
        if label.split(whereSeparator: \.isWhitespace).joined(separator: " ") == label { candidates.insert(MarkdownEscaping.heading(label)) }
        let needed = source.utf8.count + markdown.utf8.count * candidates.count
        // Nach dem Suchbudget bleibt das Ziel separat erhalten; wiederholte
        // Fundstellensuche darf nicht quadratisch über große Seiten laufen.
        guard needed <= 512 * 1_024 * 1_024 - searchBytes else { return nil }
        searchBytes += needed
        guard uniqueRange(label, in: source) != nil else { return nil }
        let ranges = Set(candidates.compactMap { uniqueRange($0, in: markdown) })
        return ranges.count == 1 ? ranges.first : nil
    }
    private func uniqueRange(_ label: String, in text: String) -> Range<String.Index>? {
        guard !label.isEmpty, let first = text.range(of: label) else { return nil }
        let next = text.index(after: first.lowerBound)
        return text.range(of: label, range: next..<text.endIndex) == nil ? first : nil
    }
    private func linkTarget(_ annotation: PDFAnnotation, location: ConversionLocation, fields: inout [String]) -> String? {
        let action = annotation.action
        if let named = action as? PDFActionNamed {
            let number: Int?
            switch named.name {
            case .firstPage: number = 1
            case .lastPage: number = document.pageCount
            case .nextPage: number = (location.page ?? 0) + 1
            case .previousPage: number = (location.page ?? 0) - 1
            default: number = nil
            }
            if let number {
                fields.append("Target page (source): \(number)")
                guard (1...document.pageCount).contains(number) else { warn("pdf.linkUnavailable", "A static PDF page jump has no page target.", location, kind: .contentLoss); return nil }
                guard selectedPages.contains(number) else { warn("pdf.linkExcluded", "A PDF link points to an excluded page; its visible text was retained without a dead link.", location, kind: .contentLoss); return nil }
                return "#pmt-pdf-page-\(number)"
            }
        }
        if let action, !(action is PDFActionURL), !(action is PDFActionGoTo) {
            fields.append("Action type (not executed): " + action.type)
            warn("pdf.annotationActionNotRepresented", "An unsupported PDF link action was not executed; its available text and metadata were retained.", location, kind: .contentLoss); return nil
        }
        if let destination = (action as? PDFActionGoTo)?.destination ?? annotation.destination {
            guard let page = destination.page else { warn("pdf.linkUnavailable", "An internal PDF link has no page target.", location, kind: .contentLoss); return nil }
            let index = document.index(for: page)
            guard index != NSNotFound, index < document.pageCount else { warn("pdf.linkUnavailable", "An internal PDF target is outside this document.", location, kind: .contentLoss); return nil }
            fields.append("Target page (source): \(index + 1)")
            let point = destination.point
            if point.x.isFinite, point.y.isFinite { fields.append("Target point (source): " + [point.x,point.y].map(coordinate).joined(separator: ", ")) }
            guard selectedPages.contains(index + 1) else { warn("pdf.linkExcluded", "A PDF link points to an excluded page; its visible text was retained without a dead link.", location, kind: .contentLoss); return nil }
            return "#pmt-pdf-page-\(index + 1)"
        }
        if let url = (action as? PDFActionURL)?.url ?? annotation.url {
            guard let target = DocumentLinkTarget.external(url.absoluteString) else {
                guard url.absoluteString.utf8.count <= 65_536 else { warn("pdf.linkUnsafe", "A PDF link target exceeds the supported metadata limit.", location, kind: .contentLoss); return nil }
                fields.append("Link target (source, inactive): " + url.absoluteString)
                warn("pdf.linkUnsafe", "An unsafe or unsupported PDF link target was retained as text only.", location, kind: .contentLoss); return nil
            }
            return target
        }
        warn("pdf.linkUnavailable", "A PDF link has no readable target; its available text and metadata were retained.", location, kind: .contentLoss)
        return nil
    }
    private func valid(_ rectangle: CGRect) -> Bool {
        rectangle.minX.isFinite && rectangle.minY.isFinite && rectangle.width.isFinite && rectangle.height.isFinite && rectangle.width > 0 && rectangle.height > 0
    }
    private func coordinate(_ value: CGFloat) -> String {
        String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
    private func literal(_ text: String) -> String {
        // Auch automatische Web-/Mail-Links dürfen aus Kommentaren oder
        // Metadaten keine zusätzlichen Linkdefinitionen machen.
        MarkdownEscaping.literalBlock(text).replacingOccurrences(of: ":", with: "\\:").replacingOccurrences(of: "@", with: "\\@").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\"", with: "\\\"")
    }
    private func dateValue(_ value: Any?) -> String? {
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        return value as? String
    }
    private func account(_ bytes: Int) throws {
        guard bytes <= 8 * 1_024 * 1_024 - annotationBytes else { throw ImportFailure("PDF annotations exceed 8 MiB") }
        annotationBytes += bytes
    }
    private func warn(_ code: String, _ message: String, _ location: ConversionLocation, kind: ConversionDiagnosticKind = .approximation) {
        diagnostics.append(.init(code: code, message: message, location: location, kind: kind))
    }
}
