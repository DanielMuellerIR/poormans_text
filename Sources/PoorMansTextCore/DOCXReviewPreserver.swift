import Foundation

/// Anmerkungen werden vor Pandoc in der verifizierten privaten Kopie verankert.
/// Erst nach der HTML-Schlussstrecke entstehen sichtbare Markdown-Markierungen;
/// fremde Span-Klassen und Fußnotennummern sind dafür kein zuverlässiger Vertrag.
final class DOCXReviewPreserver {
    private static let wordNamespaces = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main",
    ]
    private static let dateUTCNamespace = "http://schemas.microsoft.com/office/word/2023/wordml/word16du"
    private struct Comment {
        let number: Int
        let text: String
        let author: String?
        let date: String?
        let dateUTC: String?
        var context = ""
        var location: ConversionLocation
        var starts = 0
        var ends = 0
        var references = 0
    }
    private struct Marker {
        let markdown: String
        let location: ConversionLocation
        let commentID: String?
    }
    private struct Change {
        let title: String
        let text: String
        let location: ConversionLocation
        let tokens: [String]
    }
    private let token = "PMTDOCX" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var markers: [String: Marker] = [:]
    private var comments: [String: Comment] = [:]
    private var commentOrder: [String] = []
    private var changes: [Change] = []
    private var markerBytes = 0
    private var revisionBytes = 0
    private var diagnostics = BoundedConversionDiagnostics()
    var warnings: [ConversionWarning] { diagnostics.result }

    static func commentPart(reader: any ZIPPackageReading, mainPart: String) throws -> String? {
        try relatedPart(reader: reader, mainPart: mainPart, name: "comments")
    }
    static func noteParts(reader: any ZIPPackageReading, mainPart: String) throws -> [String] {
        try ["footnotes", "endnotes"].compactMap { try relatedPart(reader: reader, mainPart: mainPart, name: $0) }
    }
    private static func relatedPart(reader: any ZIPPackageReading, mainPart: String, name: String) throws -> String? {
        let directory = (mainPart as NSString).deletingLastPathComponent
        let relationships = (directory.isEmpty ? "" : directory + "/") + "_rels/" + (mainPart as NSString).lastPathComponent + ".rels"
        if let data = try reader.dataIfPresent(named: relationships) {
            let root = try ImportXML.parse(data)
            let types = ["http://schemas.openxmlformats.org/officeDocument/2006/relationships/", "http://purl.oclc.org/ooxml/officeDocument/relationships/"].map { $0 + name }
            let matches = root.children.filter { $0.name == "Relationship" &&
                $0.namespace == "http://schemas.openxmlformats.org/package/2006/relationships" &&
                types.contains($0.attribute("Type") ?? "") }
            guard matches.count <= 1 else { throw ImportFailure("DOCX declares multiple \(name) parts") }
            if let relation = matches.first {
                guard relation.attribute("TargetMode")?.lowercased() != "external", let target = relation.attribute("Target") else {
                    throw ImportFailure("DOCX \(name) must be a local package part")
                }
                let path = try ImportPackagePath.resolve(target.hasPrefix("/") ? String(target.dropFirst()) : target, relativeTo: target.hasPrefix("/") ? "package.xml" : mainPart)
                guard reader.entryNames.contains(path) else { throw ImportFailure("the DOCX \(name) part is missing") }
                return path
            }
        }
        let fallback = (directory.isEmpty ? "" : directory + "/") + name + ".xml"
        return reader.entryNames.contains(fallback) ? fallback : nil
    }

    func prepare(reader: ZIPPackageReader, mainPart: String, mode: DOCXChangeMode, workDirectory: URL) throws {
        try readComments(reader: reader, mainPart: mainPart)
        let noteNames = ["footnotes", "endnotes"]
        let notes = try noteNames.compactMap { name in try Self.relatedPart(reader: reader, mainPart: mainPart, name: name).map { (path: $0, type: name) } }
        let parts = [mainPart] + notes.map(\.path)
        guard Set(parts).count == parts.count else { throw ImportFailure("DOCX review relationships reuse the same part for incompatible roles") }
        let patch = workDirectory.appendingPathComponent("docx-review-patch")
        try FileManager.default.createDirectory(at: patch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var patched: [String] = []
        var added = Set<String>()
        var totalBytes = 0
        var contextComparisons = 0
        for part in parts {
            try ConversionExecution.check()
            let data = try reader.data(named: part)
            guard data.count <= 32 * 1_024 * 1_024 - totalBytes else { throw ImportFailure("DOCX review XML exceeds 32 MiB") }
            totalBytes += data.count
            let document = try Self.xml(data)
            guard let root = document.rootElement(), !document.xmlString.contains(token) else { throw ImportFailure("DOCX review XML has an invalid root or conflicting markers") }
            guard Self.isWord(root, part == mainPart ? "document" : notes.first(where: { $0.path == part })!.type) else {
                throw ImportFailure("a DOCX review part has an invalid WordprocessingML root")
            }
            try Self.separateNoteReferenceRuns(in: root)
            let nodes = try Self.elements(root)
            let locations = try annotateComments(nodes, part: part, mainPart: mainPart, contextComparisons: &contextComparisons)
            try annotateChanges(nodes, locations: locations, part: part, mode: mode)
            let destination = patch.appendingPathComponent(part)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let patchedData = document.xmlData(options: .nodeCompactEmptyElement)
            guard patchedData.count <= 32 * 1_024 * 1_024 else { throw ImportFailure("prepared DOCX review XML exceeds 32 MiB") }
            try patchedData.write(to: destination, options: .atomic)
            patched.append(part)
            if part != mainPart {
                // Pandoc liest Noten unter festen word/...-Pfaden und ignoriert
                // dafür abweichende Ziele aus den OPC-Beziehungen.
                let canonical = "word/" + root.localName! + ".xml"
                if canonical != part {
                    guard !reader.entryNames.contains(canonical) else { throw ImportFailure("a nonstandard DOCX note part conflicts with Pandoc's canonical note path") }
                    try writePatch(patchedData, path: canonical, directory: patch)
                    patched.append(canonical); added.insert(canonical)
                    let originalRelations = Self.relationshipPart(for: part)
                    let canonicalRelations = Self.relationshipPart(for: canonical)
                    if let data = try reader.dataIfPresent(named: originalRelations) {
                        guard !reader.entryNames.contains(canonicalRelations) else { throw ImportFailure("DOCX note relationships conflict with the canonical note path") }
                        let relationships = try Self.xml(data)
                        for element in try Self.elements(relationships.rootElement()!) where element.localName == "Relationship" {
                            if element.attribute(forName: "TargetMode")?.stringValue?.lowercased() == "external" { continue }
                            guard let attribute = element.attribute(forName: "Target"), let target = attribute.stringValue else { throw ImportFailure("a DOCX note relationship has no target") }
                            let resolved = try ImportPackagePath.resolve(target.hasPrefix("/") ? String(target.dropFirst()) : target, relativeTo: target.hasPrefix("/") ? "package.xml" : part)
                            attribute.stringValue = "/" + resolved
                        }
                        try writePatch(relationships.xmlData(options: .nodeCompactEmptyElement), path: canonicalRelations, directory: patch)
                        patched.append(canonicalRelations); added.insert(canonicalRelations)
                    }
                    diagnostics.append(.init(code: "docx.notePartNormalized", message: "A nonstandard note part was normalized in the private copy so Pandoc retains its content.", location: .init(note: part), kind: .information))
                }
            }
        }
        if !added.isEmpty {
            let types = try Self.xml(reader.data(named: "[Content_Types].xml"))
            let root = types.rootElement()!
            for part in added where part.hasSuffix(".xml") {
                let contentType = "application/vnd.openxmlformats-officedocument.wordprocessingml." + (part as NSString).lastPathComponent.replacingOccurrences(of: ".xml", with: "") + "+xml"
                let existing = (root.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == "Override" && $0.attribute(forName: "PartName")?.stringValue == "/" + part }
                if !existing.isEmpty {
                    guard existing.count == 1, existing[0].attribute(forName: "ContentType")?.stringValue == contentType else { throw ImportFailure("a normalized DOCX note has conflicting content types") }
                    continue
                }
                let element = XMLElement(name: Self.qualified("Override", near: root), uri: root.uri)
                element.addAttribute(XMLNode.attribute(withName: "PartName", stringValue: "/" + part) as! XMLNode)
                element.addAttribute(XMLNode.attribute(withName: "ContentType", stringValue: contentType) as! XMLNode)
                root.addChild(element)
            }
            try writePatch(types.xmlData(options: .nodeCompactEmptyElement), path: "[Content_Types].xml", directory: patch)
            patched.append("[Content_Types].xml")
        }
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-0", reader.url.path, "-nw", "--"] + patched, currentDirectory: patch)
        guard result.status == 0 else { throw ImportFailure("the private DOCX review copy could not be packaged") }
        try ZIPArchiveInspector.withVerifiedReader(at: reader.url) { updated in
            guard updated.entryNames == reader.entryNames.union(added) else { throw ImportFailure("DOCX review preparation changed unexpected package entries") }
        }
    }

    func finish(markdownURL: URL) throws {
        let source = try String(contentsOf: markdownURL, encoding: .utf8)
        guard source.utf8.count <= 64 * 1_024 * 1_024 else { throw ImportFailure("DOCX review Markdown exceeds 64 MiB") }
        let regex = try NSRegularExpression(pattern: token + "[0-9]+END")
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var output = ""
        var outputBytes = 0
        var cursor = source.startIndex
        var seen = Set<String>()
        var anchoredComments = Set<String>()
        for match in matches {
            try ConversionExecution.check()
            guard let range = Range(match.range, in: source), let marker = markers[String(source[range])], seen.insert(String(source[range])).inserted else {
                throw ImportFailure("DOCX review markers were duplicated or changed during conversion")
            }
            let prefix = source[cursor..<range.lowerBound]
            output += prefix
            outputBytes += prefix.utf8.count
            let offset = outputBytes
            output += marker.markdown
            outputBytes += marker.markdown.utf8.count
            ConversionExecution.current?.recording?.record(marker.location, offset: offset, length: marker.markdown.utf8.count)
            if let id = marker.commentID { anchoredComments.insert(id) }
            cursor = range.upperBound
        }
        output += source[cursor...]
        outputBytes += source[cursor...].utf8.count
        guard !output.contains(token) else { throw ImportFailure("an internal DOCX review marker was not resolved") }
        var appendixBytes = 0
        func append(_ text: String, location: ConversionLocation) throws {
            guard text.utf8.count <= 8 * 1_024 * 1_024 - appendixBytes else { throw ImportFailure("DOCX review annotations exceed 8 MiB") }
            appendixBytes += text.utf8.count
            guard text.utf8.count <= 64 * 1_024 * 1_024 - outputBytes else { throw ImportFailure("DOCX review Markdown exceeds 64 MiB") }
            let offset = outputBytes
            output += text
            outputBytes += text.utf8.count
            ConversionExecution.current?.recording?.record(location, offset: offset, length: text.utf8.count)
        }
        if !commentOrder.isEmpty { let heading = "\n\n## Document comments\n"; output += heading; outputBytes += heading.utf8.count }
        for id in commentOrder {
            try ConversionExecution.check()
            let comment = comments[id]!
            let metadata = (["Source comment ID: " + id] + [comment.author.map { "Author: " + $0 }, comment.date.map { "Date: " + $0 }, comment.dateUTC.map { "UTC date: " + $0 }].compactMap { $0 }).joined(separator: "\n")
            let context = comment.context.isEmpty ? "Source reference: no textual range available." : "Source excerpt: " + comment.context
            let text = "\n### Comment \(comment.number)\n\n" + MarkdownEscaping.literalBlock(metadata) + "\n\n" +
                MarkdownEscaping.literalBlock(context) + "\n\n" + MarkdownEscaping.literalBlock(comment.text) + "\n"
            try append(text, location: comment.location)
            diagnostics.append(.init(code: "docx.commentPreserved", message: "Comment \(comment.number) was retained with its available author, date and source excerpt.", location: comment.location, kind: .information))
            if !anchoredComments.contains(id) {
                diagnostics.append(.init(code: "docx.commentDetached", message: "The comment's source anchor was removed by the selected change mode or was not converted; the annotation and available source excerpt were retained separately.", location: comment.location))
            }
            if comment.starts != comment.ends || comment.starts > 1 || comment.references > 1 {
                diagnostics.append(.init(code: "docx.commentAnchorIncomplete", message: "The comment has an incomplete or repeated range; visible source markers and the annotation were retained without inventing a single range.", location: comment.location))
            }
        }
        let separateChanges = changes.filter { $0.tokens.isEmpty || !$0.tokens.allSatisfy(seen.contains) }
        if !separateChanges.isEmpty { let heading = "\n\n## Additional revision information\n"; output += heading; outputBytes += heading.utf8.count }
        for change in separateChanges {
            try append("\n" + MarkdownEscaping.literalBlock(change.title) + "\n\n" + MarkdownEscaping.literalBlock(change.text) + "\n", location: change.location)
            if !change.tokens.isEmpty {
                diagnostics.append(.init(code: "docx.changeAnchorUnavailable", message: "A tracked change was not rendered at its source position; its text and revision metadata were retained separately.", location: change.location))
            }
        }
        guard outputBytes <= 64 * 1_024 * 1_024 else { throw ImportFailure("DOCX review Markdown exceeds 64 MiB") }
        try Data(output.utf8).write(to: markdownURL, options: .atomic)
    }

    private func readComments(reader: any ZIPPackageReading, mainPart: String) throws {
        if let part = try Self.commentPart(reader: reader, mainPart: mainPart) {
            let root = try Self.xml(reader.data(named: part)).rootElement()!
            guard Self.isWord(root, "comments") else { throw ImportFailure("the DOCX comments part has an invalid root") }
            if reader.entryNames.contains(where: { $0.hasSuffix("/commentsExtended.xml") || $0.hasSuffix("/commentsExtensible.xml") }) {
                diagnostics.append(.init(code: "docx.commentThreadFlattened", message: "Comment bodies were retained as separate annotations; reply relationships and resolved-thread state were not reconstructed."))
            }
            for node in try Self.elements(root) where Self.isWord(node, "comment") {
                guard let id = Self.attribute("id", node), comments[id] == nil, comments.count < 4_096 else {
                    throw ImportFailure("DOCX comments have missing/duplicate identifiers or exceed 4096 entries")
                }
                let text = try plainText(node)
                comments[id] = Comment(number: comments.count + 1, text: text, author: Self.attribute("author", node),
                    date: Self.attribute("date", node), dateUTC: Self.utcDate(node), location: .init(note: "Comment \(comments.count + 1)"))
                commentOrder.append(id)
                if try Self.elements(node).contains(where: { ["drawing", "object", "pict", "footnoteReference", "endnoteReference"].contains($0.localName ?? "") }) {
                    diagnostics.append(.init(code: "docx.commentObjectNotRepresented", message: "A comment contains a graphic, object or note reference; its textual content was retained.", location: comments[id]?.location, kind: .contentLoss))
                }
                if try Self.elements(node).contains(where: { Self.isWord($0, "hyperlink") || Self.isWord($0, "tbl") }) {
                    diagnostics.append(.init(code: "docx.commentStructureFlattened", message: "Comment tables or hyperlinks were flattened to their visible text; hyperlink targets and table layout were not retained.", location: comments[id]?.location))
                }
            }
        }
    }

    private static func separateNoteReferenceRuns(in root: XMLElement) throws {
        // Pandocs DOCX-Leser übernimmt pro Run nur den ersten Notenverweis.
        // Getrennte Runs bewahren mehrere Verweise und benachbarten Text.
        for node in try Self.elements(root) where Self.isWord(node, "r") {
            let children = (node.children ?? []).compactMap { $0 as? XMLElement }
            let content = children.filter { !Self.isWord($0, "rPr") }
            guard content.count > 1, content.contains(where: { Self.isWord($0, "footnoteReference") || Self.isWord($0, "endnoteReference") }),
                  let parent = node.parent as? XMLElement else { continue }
            let properties = children.first { Self.isWord($0, "rPr") }
            let position = node.index
            for (index, child) in content.enumerated() {
                let separate = node.copy() as! XMLElement
                separate.setChildren([])
                if let properties { separate.addChild(properties.copy() as! XMLNode) }
                separate.addChild(child.copy() as! XMLNode)
                parent.insertChild(separate, at: position + index)
            }
            node.detach()
        }
    }

    private func annotateComments(_ nodes: [XMLElement], part: String, mainPart: String, contextComparisons: inout Int) throws -> [ObjectIdentifier: ConversionLocation] {
        var locations: [ObjectIdentifier: ConversionLocation] = [:]
        var paragraph = 0
        var active = Set<String>()
        for node in nodes {
            try ConversionExecution.check()
            if Self.isWord(node, "p") { paragraph += 1 }
            let location = ConversionLocation(paragraph: part == mainPart ? paragraph : nil, note: part == mainPart ? nil : part)
            locations[ObjectIdentifier(node)] = location
            let name = node.localName ?? ""
            if Self.isWord(node), ["commentRangeStart", "commentRangeEnd", "commentReference"].contains(name) {
                guard let id = Self.attribute("id", node) else { throw ImportFailure("a DOCX comment anchor has no identifier") }
                if comments[id] == nil {
                    guard comments.count < 4_096 else { throw ImportFailure("DOCX exceeds 4096 comments") }
                    comments[id] = Comment(number: comments.count + 1, text: "[Missing comment definition]", author: nil, date: nil, dateUTC: nil, location: location)
                    commentOrder.append(id)
                    diagnostics.append(.init(code: "docx.commentDefinitionMissing", message: "A DOCX comment reference has no definition; its reference was retained.", location: location, kind: .contentLoss))
                }
                var comment = comments[id]!
                if comment.starts + comment.ends + comment.references == 0 {
                    comment.location = .init(paragraph: location.paragraph, note: "Comment \(comment.number)" + (part == mainPart ? "" : " (\(part))"))
                }
                if name == "commentRangeStart" { comment.starts += 1; active.insert(id) }
                if name == "commentRangeEnd" { comment.ends += 1; active.remove(id) }
                if name == "commentReference" { comment.references += 1 }
                comments[id] = comment
            } else if Self.isWord(node), ["t", "delText", "tab", "br", "cr", "drawing"].contains(name) {
                let text = name == "drawing" ? "[Image]" : name == "tab" ? "\t" : ["br", "cr"].contains(name) ? "\n" : node.stringValue ?? ""
                guard active.count <= 1_000_000 - contextComparisons else { throw ImportFailure("DOCX comment ranges exceed the context comparison limit") }
                contextComparisons += active.count
                for id in active {
                    let previous = comments[id]?.context ?? ""
                    comments[id]?.context = String((previous + text).prefix(1_024))
                }
            }
        }
        var paragraphExcerpts: [ObjectIdentifier: String] = [:]
        for node in nodes where Self.isWord(node) && ["commentRangeStart", "commentRangeEnd", "commentReference"].contains(node.localName ?? "") {
            let id = Self.attribute("id", node)!
            let comment = comments[id]!
            let label = node.localName == "commentRangeStart" ? "start" : node.localName == "commentRangeEnd" ? "end" : "reference"
            if label == "reference", comment.context.isEmpty, let p = Self.ancestor(node, named: "p") {
                let key = ObjectIdentifier(p)
                if paragraphExcerpts[key] == nil { paragraphExcerpts[key] = String(try plainText(p).prefix(1_024)) }
                comments[id]?.context = paragraphExcerpts[key] ?? ""
            }
            let marker = try makeMarker(" \\[Comment \(comment.number) \(label)\\] ", location: comment.location, commentID: id)
            if !insert(marker, at: node) {
                diagnostics.append(.init(code: "docx.commentAnchorUnavailable", message: "A DOCX comment anchor could not be placed in the converted text; its annotation was retained separately.", location: comment.location))
            }
            node.detach()
        }
        return locations
    }

    private func annotateChanges(_ nodes: [XMLElement], locations: [ObjectIdentifier: ConversionLocation], part: String, mode: DOCXChangeMode) throws {
        for node in nodes where Self.isWord(node) {
            var ancestor = node.parent
            var historicalProperties = false
            while let current = ancestor {
                if let element = current as? XMLElement, Self.isWord(element), element.localName?.hasSuffix("Change") == true { historicalProperties = true; break }
                ancestor = current.parent
            }
            if historicalProperties { continue }
            let name = node.localName ?? ""
            let location = locations[ObjectIdentifier(node)] ?? .init(note: part)
            if ["ins", "del", "moveFrom", "moveTo"].contains(name) {
                let deletion = name == "del" || name == "moveFrom"
                let kind = name == "moveFrom" ? "Move from" : name == "moveTo" ? "Move to" : deletion ? "Deletion" : "Insertion"
                let title = metadata(kind, node: node)
                if let parent = node.parent as? XMLElement, Self.isWord(parent, "trPr"), let row = parent.parent as? XMLElement, Self.isWord(row, "tr") {
                    guard (parent.children ?? []).compactMap({ $0 as? XMLElement }).filter({ Self.isWord($0, "ins") || Self.isWord($0, "del") }).count == 1 else {
                        throw ImportFailure("a DOCX table row has ambiguous revision markers")
                    }
                    if (mode == .accept && deletion) || (mode == .reject && !deletion) { row.detach() }
                    else if mode == .mark {
                        let paragraphs = try Self.elements(row).filter { Self.isWord($0, "p") }
                        let text = try plainText(row)
                        if let first = paragraphs.first, let last = paragraphs.last {
                            let start = try makeMarker(" **\\[\(MarkdownEscaping.inlineLiteral(title)): row\\]** ", location: location)
                            let end = try makeMarker(" **\\[End \(kind.lowercased()) row\\]** ", location: location)
                            first.insertChild(run(start, near: first), at: 0); last.addChild(run(end, near: last))
                            try rememberChange(.init(title: title + ": row", text: text, location: location, tokens: [start, end]))
                        } else { try rememberChange(.init(title: title + ": row", text: text, location: location, tokens: [])) }
                    }
                    node.detach()
                } else if let parent = node.parent as? XMLElement, Self.isWord(parent, "rPr"), Self.ancestor(node, named: "pPr") != nil {
                    if mode == .mark, let p = Self.ancestor(node, named: "p") {
                        let marker = try makeMarker(" **\\[\(MarkdownEscaping.inlineLiteral(title)): paragraph break\\]** ", location: location)
                        p.addChild(run(marker, near: p))
                        try rememberChange(.init(title: title + ": paragraph break", text: "", location: location, tokens: [marker]))
                    }
                } else if Self.ancestor(node, named: "p") != nil {
                    let text = try plainText(node)
                    if mode == .mark {
                        let start = try makeMarker(" **\\[\(MarkdownEscaping.inlineLiteral(title))\\]** ", location: location)
                        let end = try makeMarker(" **\\[End \(kind.lowercased())\\]** ", location: location)
                        node.insertChild(run(start, near: node, deleted: deletion), at: 0)
                        node.addChild(run(end, near: node, deleted: deletion))
                        try rememberChange(.init(title: title, text: text, location: location, tokens: [start, end]))
                    }
                    if name == "moveFrom" || name == "moveTo" {
                        node.name = Self.qualified(deletion ? "del" : "ins", near: node)
                        if deletion {
                            for child in try Self.elements(node) where Self.isWord(child, "t") { child.name = Self.qualified("delText", near: child) }
                        }
                    }
                } else {
                    diagnostics.append(.init(code: "docx.structuralChangeNotRepresented", message: "A tracked DOCX structure has no supported text anchor; its revision metadata was retained separately.", location: location))
                    try rememberChange(.init(title: title, text: try plainText(node), location: location, tokens: []))
                }
            } else if name.hasSuffix("Change") || ["cellIns", "cellDel", "cellMerge"].contains(name) {
                diagnostics.append(.init(code: "docx.formatChangeNotRepresented", message: "Tracked DOCX formatting or cell-property history cannot be reconstructed as Markdown; current readable content and revision metadata were retained.", location: location, kind: .contentLoss))
                try rememberChange(.init(title: metadata("Formatting/structure change", node: node), text: "", location: location, tokens: []))
            }
        }
    }

    private func makeMarker(_ markdown: String, location: ConversionLocation, commentID: String? = nil) throws -> String {
        guard markers.count < 32_768, markdown.utf8.count <= 8 * 1_024 * 1_024 - markerBytes else { throw ImportFailure("DOCX review markers exceed their count or 8 MiB limit") }
        markerBytes += markdown.utf8.count
        let value = token + String(markers.count) + "END"
        markers[value] = Marker(markdown: markdown, location: location, commentID: commentID)
        return value
    }
    private func rememberChange(_ change: Change) throws {
        let bytes = change.text.utf8.count + change.title.utf8.count
        guard changes.count < 10_000, bytes <= 8 * 1_024 * 1_024 - revisionBytes else {
            throw ImportFailure("DOCX revision information exceeds 10000 changes or 8 MiB")
        }
        revisionBytes += bytes
        changes.append(change)
    }
    private func metadata(_ kind: String, node: XMLElement) -> String {
        ([kind] + [Self.attribute("author", node), Self.attribute("date", node), Self.utcDate(node).map { "UTC: " + $0 }].compactMap { $0?.split(whereSeparator: \.isWhitespace).joined(separator: " ") }).joined(separator: "; ")
    }
    private func writePatch(_ data: Data, path: String, directory: URL) throws {
        let destination = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
    private static func relationshipPart(for part: String) -> String {
        let directory = (part as NSString).deletingLastPathComponent
        return (directory.isEmpty ? "" : directory + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
    }
    private func insert(_ marker: String, at node: XMLElement) -> Bool {
        var position = node
        while let parent = position.parent as? XMLElement, Self.isWord(parent, "r") { position = parent }
        guard let parent = position.parent as? XMLElement, Self.isWord(parent),
              ["p", "hyperlink", "ins", "del", "moveFrom", "moveTo", "sdtContent"].contains(parent.localName ?? "") else { return false }
        let deletion = Self.ancestor(node, named: "del") != nil || Self.ancestor(node, named: "moveFrom") != nil
        parent.insertChild(run(marker, near: node, deleted: deletion), at: position.index)
        return true
    }
    private func run(_ marker: String, near node: XMLElement, deleted: Bool = false) -> XMLElement {
        let ns = node.uri ?? Self.wordNamespaces[0]
        let run = XMLElement(name: Self.qualified("r", near: node), uri: ns)
        let text = XMLElement(name: Self.qualified(deleted ? "delText" : "t", near: node), uri: ns)
        text.addAttribute(XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode)
        text.stringValue = " " + marker + " "
        run.addChild(text)
        return run
    }
    private func plainText(_ root: XMLElement) throws -> String {
        var text = ""
        var bytes = 0
        for node in try Self.elements(root) where Self.isWord(node) {
            let name = node.localName ?? ""
            let value: String
            switch name {
            case "t", "delText": value = node.stringValue ?? ""
            case "tab": value = "\t"
            case "br", "cr", "p": value = "\n"
            default: continue
            }
            if value.contains(token) { continue }
            guard value.utf8.count <= 8 * 1_024 * 1_024 - bytes else { throw ImportFailure("DOCX review text exceeds 8 MiB") }
            bytes += value.utf8.count
            text += value
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func xml(_ data: Data) throws -> XMLDocument {
        _ = try ImportXML.parse(data)
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveAll])
        if let dtd = document.dtd, dtd.systemID != nil || dtd.publicID != nil || (dtd.children ?? []).contains(where: { $0.kind == .entityDeclaration }) {
            throw ImportFailure("DOCX review XML entity declarations and external DTDs are not supported")
        }
        document.characterEncoding = "UTF-8"
        guard document.rootElement() != nil else { throw ImportFailure("DOCX review XML has no root") }
        return document
    }
    private static func elements(_ root: XMLElement) throws -> [XMLElement] {
        var result: [XMLElement] = []
        var pending = [root]
        while let node = pending.popLast() {
            try ConversionExecution.check()
            guard result.count < 200_000 else { throw ImportFailure("DOCX review XML exceeds 200000 elements") }
            result.append(node)
            pending += (node.children ?? []).compactMap { $0 as? XMLElement }.reversed()
        }
        return result
    }
    private static func isWord(_ node: XMLElement, _ name: String? = nil) -> Bool {
        wordNamespaces.contains(node.uri ?? "") && (name == nil || node.localName == name)
    }
    private static func attribute(_ name: String, _ node: XMLElement) -> String? {
        wordNamespaces.lazy.compactMap { node.attribute(forLocalName: name, uri: $0)?.stringValue }.first
    }
    private static func utcDate(_ node: XMLElement) -> String? {
        node.attribute(forLocalName: "dateUtc", uri: dateUTCNamespace)?.stringValue
    }
    private static func qualified(_ name: String, near node: XMLElement) -> String {
        node.prefix.map { $0.isEmpty ? name : $0 + ":" + name } ?? name
    }
    private static func ancestor(_ node: XMLNode, named name: String) -> XMLElement? {
        var parent = node.parent
        while let current = parent {
            if let element = current as? XMLElement, isWord(element, name) { return element }
            parent = current.parent
        }
        return nil
    }
}
