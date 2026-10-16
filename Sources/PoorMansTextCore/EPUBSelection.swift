import Foundation

public struct EPUBChapterSummary: Codable, Hashable, Sendable {
    public let number: Int
    public let path: String
    public let title: String?
    public let isLinear: Bool
    public let isReadable: Bool
}

public struct EPUBNavigationEntry: Codable, Hashable, Sendable {
    public let chapter: Int
    public let title: String
    public let fragment: String?
}

public struct EPUBContentSummary: Codable, Sendable {
    public let sourceIdentity: ConversionSourceIdentity
    public let chapterCount: Int
    public let chapters: [EPUBChapterSummary]
    public let chaptersTruncated: Bool
    public let navigation: [EPUBNavigationEntry]
    public let navigationTruncated: Bool
    public let diagnostics: [ConversionWarning]
    public static let maximumSummaryChapters = 500
}

/// Die Auswahl ändert ausschließlich eine bereits verifizierte private Kopie.
/// Generierte Anker entstehen erst nach Pandocs Abschirmung fremden HTMLs.
final class EPUBSelectionPackage {
    static let opf = "http://www.idpf.org/2007/opf"
    private static let anchorContainers: Set<String> = ["body", "div", "section", "article", "main", "p", "li", "td", "th", "blockquote", "header", "footer", "nav", "figure", "figcaption"]
    static let xhtml = "http://www.w3.org/1999/xhtml"
    struct Chapter {
        let number: Int
        let id: String
        let path: String
        let linear: Bool
        let readable: Bool
    }
    let reader: any ZIPPackageReading
    let opfPath: String
    let document: XMLDocument
    let spine: XMLElement
    let chapters: [Chapter]
    private let manifest: [String: (path: String?, type: String, properties: [String])]
    private let token = "PMTEPUB" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var markers: [String: String] = [:]
    private var linkTokens: [String: String] = [:]
    private var chosen = [Chapter]()
    private var diagnosticStorage = BoundedConversionDiagnostics()
    var diagnostics: [ConversionWarning] { diagnosticStorage.result }

    init(reader: any ZIPPackageReading) throws {
        self.reader = reader
        let container = try ImportXML.parse(reader.data(named: "META-INF/container.xml"))
        guard container.name == "container", container.namespace == EPUBMetadataReader.containerNamespace,
              let root = container.elements("rootfiles", namespace: container.namespace).first?.elements("rootfile", namespace: container.namespace).first,
              let rawPath = root.attribute("full-path") else { throw ImportFailure("the EPUB container has no package root") }
        opfPath = try ImportPackagePath.resolve(rawPath, relativeTo: "container-root")
        document = try Self.xml(reader.data(named: opfPath))
        guard let package = document.rootElement(), package.localName == "package", package.uri == Self.opf,
              package.elements(forLocalName: "manifest", uri: Self.opf).count == 1,
              package.elements(forLocalName: "spine", uri: Self.opf).count == 1,
              let manifestNode = package.elements(forLocalName: "manifest", uri: Self.opf).first,
              let spineNode = package.elements(forLocalName: "spine", uri: Self.opf).first else { throw ImportFailure("the EPUB package requires one manifest and spine") }
        spine = spineNode
        let items = manifestNode.elements(forLocalName: "item", uri: Self.opf)
        guard items.count <= 10_000 else { throw ImportFailure("the EPUB manifest exceeds 10000 items") }
        var entries: [String: (path: String?, type: String, properties: [String])] = [:]
        for item in items {
            guard let id = item.attribute(forName: "id")?.stringValue, !id.isEmpty, entries[id] == nil,
                  let href = item.attribute(forName: "href")?.stringValue,
                  let type = item.attribute(forName: "media-type")?.stringValue else { throw ImportFailure("the EPUB manifest has missing or duplicate item identifiers") }
            entries[id] = (try? ImportPackagePath.resolve(href, relativeTo: opfPath), type,
                (item.attribute(forName: "properties")?.stringValue ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        }
        manifest = entries
        let refs = spineNode.elements(forLocalName: "itemref", uri: Self.opf)
        guard !refs.isEmpty, refs.count <= 1_000 else { throw ImportFailure("the EPUB requires between 1 and 1000 spine entries") }
        var units = [Chapter](), ids = Set<String>(), paths = Set<String>()
        for (index, ref) in refs.enumerated() {
            guard let id = ref.attribute(forName: "idref")?.stringValue, ids.insert(id).inserted,
                  let item = entries[id], let path = item.path, paths.insert(path).inserted else {
                throw ImportFailure("the EPUB spine has a missing, unsafe or repeated content document; repeated documents cannot be selected unambiguously")
            }
            let linear = ref.attribute(forName: "linear")?.stringValue ?? "yes"
            guard ["yes", "no"].contains(linear) else { throw ImportFailure("the EPUB spine has an invalid linear attribute") }
            units.append(.init(number: index + 1, id: id, path: path, linear: linear == "yes",
                readable: item.type == "application/xhtml+xml" && reader.entryNames.contains(path)))
        }
        guard units.contains(where: \.linear) else { throw ImportFailure("the EPUB spine has no primary reading order") }
        chapters = units
    }

    static func xml(_ data: Data) throws -> XMLDocument {
        _ = try ImportXML.parse(data)
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveAll])
        if let dtd = document.dtd {
            guard dtd.systemID == nil, dtd.publicID == nil, !(dtd.children ?? []).contains(where: { $0.kind == .entityDeclaration }) else {
                throw ImportFailure("EPUB XML entity declarations and external DTDs are not supported")
            }
        }
        document.characterEncoding = "UTF-8"
        return document
    }

    static func bounded(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.utf8.count > 256 else { return text }
        var bytes = Data(text.utf8.prefix(253))
        for _ in 0..<3 where String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return (String(data: bytes, encoding: .utf8) ?? "") + "…"
    }

    static func elements(_ node: XMLNode) -> [XMLElement] {
        (node.children ?? []).flatMap { child in (child as? XMLElement).map { [$0] + elements($0) } ?? [] }
    }

    func summary(identity: ConversionSourceIdentity, maximumChapters: Int) throws -> EPUBContentSummary {
        guard (1...EPUBContentSummary.maximumSummaryChapters).contains(maximumChapters) else { throw ImportFailure("the EPUB overview limit must be between 1 and 500") }
        var values = [EPUBChapterSummary]()
        for chapter in chapters.prefix(maximumChapters) {
            try ConversionExecution.check()
            var title: String?
            if chapter.readable {
                let xml = try Self.xml(reader.data(named: chapter.path))
                let nodes = Self.elements(xml)
                title = nodes.first { $0.localName == "h1" && $0.uri == Self.xhtml }?.stringValue
                    ?? nodes.first { $0.localName == "title" && $0.uri == Self.xhtml }?.stringValue
            }
            values.append(.init(number: chapter.number, path: chapter.path, title: Self.bounded(title), isLinear: chapter.linear, isReadable: chapter.readable))
        }
        let navigation = readNavigation()
        return .init(sourceIdentity: identity, chapterCount: chapters.count, chapters: values, chaptersTruncated: values.count < chapters.count,
            navigation: Array(navigation.prefix(4096)), navigationTruncated: navigation.count > 4096, diagnostics: diagnostics)
    }

    private func readNavigation() -> [EPUBNavigationEntry] {
        var result = [EPUBNavigationEntry]()
        let chapterByPath = Dictionary(uniqueKeysWithValues: chapters.map { ($0.path, $0.number) })
        for item in manifest.values.sorted(by: { ($0.path ?? "") < ($1.path ?? "") })
        where item.properties.contains("nav") || item.type == "application/x-dtbncx+xml" {
            guard let path = item.path else {
                diagnosticStorage.append(.init(code: "epub.navigationUnavailable", message: "An unsafe or external EPUB navigation resource was not loaded.", kind: .approximation))
                continue
            }
            do {
                let xml = try Self.xml(reader.data(named: path))
                guard let root = xml.rootElement(),
                      (item.type == "application/x-dtbncx+xml" ? root.localName == "ncx" : root.localName == "html" && root.uri == Self.xhtml) else { throw ImportFailure("invalid EPUB navigation root") }
                let nodes = Self.elements(xml)
                let links: [(String, String)]
                if item.type == "application/x-dtbncx+xml" {
                    links = nodes.filter { $0.localName == "navPoint" }.compactMap { point in
                        guard let href = point.elements(forLocalName: "content", uri: point.uri ?? "").first?.attribute(forName: "src")?.stringValue else { return nil }
                        return (href, point.elements(forLocalName: "navLabel", uri: point.uri ?? "").first?.stringValue ?? "")
                    }
                } else {
                    let navigationNodes = nodes.filter { $0.localName == "nav" && $0.uri == Self.xhtml }
                    let toc = navigationNodes.filter { ($0.attribute(forLocalName: "type", uri: "http://www.idpf.org/2007/ops")?.stringValue ?? "").split(whereSeparator: \.isWhitespace).contains("toc") }
                    let anchors = (toc.isEmpty ? navigationNodes : toc).flatMap(Self.elements)
                    links = anchors.filter { $0.localName == "a" && $0.uri == Self.xhtml }.compactMap { node in
                        node.attribute(forName: "href")?.stringValue.map { ($0, node.stringValue ?? "") }
                    }
                }
                for (href, title) in links {
                    let pieces = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let target = try? ImportPackagePath.resolve(String(pieces[0]), relativeTo: path),
                          let chapter = chapterByPath[target] else {
                        diagnosticStorage.append(.init(code: "epub.navigationTargetUnavailable", message: "An EPUB navigation target is missing, external or outside the spine and was omitted from the overview.", kind: .approximation))
                        continue
                    }
                    let fragment = pieces.count == 2 ? String(pieces[1]).removingPercentEncoding : nil
                    if let fragment, fragment.utf8.count > 1_024 {
                        diagnosticStorage.append(.init(code: "epub.navigationFragmentLimited", message: "An EPUB navigation fragment exceeds 1024 bytes and was omitted from the overview.", kind: .approximation))
                        continue
                    }
                    result.append(.init(chapter: chapter, title: Self.bounded(title) ?? "", fragment: fragment))
                    if result.count > 4096 { return result }
                }
            } catch {
                diagnosticStorage.append(.init(code: "epub.navigationUnavailable", message: "The EPUB navigation could not be read; the spine reading order remains available.", kind: .approximation))
            }
        }
        return result
    }

    func prepare(selection: IndexSelection, archive: URL, workDirectory: URL) throws {
        chosen = try selection.zeroBasedIndices(itemCount: chapters.count).map { chapters[$0] }
        guard chosen.allSatisfy(\.readable) else { throw ImportFailure("the selected EPUB chapters must be present local XHTML documents") }
        _ = readNavigation()
        let allPaths = Set(chapters.map(\.path))
        let patch = workDirectory.appendingPathComponent("epub-selection-patch")
        try FileManager.default.createDirectory(at: patch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var documents: [Int: XMLDocument] = [:]
        var bodies: [Int: XMLElement] = [:]
        var anchors: [String: [String: String]] = [:]
        var serial = 0
        var selectedXMLBytes = 0
        guard ([opfPath] + chosen.map(\.path)).allSatisfy({ $0.utf8.count <= 1_024 }) else { throw ImportFailure("selected EPUB paths exceed 1024 bytes") }
        for chapter in chosen {
            try ConversionExecution.check()
            let data = try reader.data(named: chapter.path)
            guard data.count <= 128 * 1_024 * 1_024 - selectedXMLBytes else { throw ImportFailure("selected EPUB chapter XML exceeds 128 MiB") }
            selectedXMLBytes += data.count
            let xml = try Self.xml(data)
            guard let root = xml.rootElement(), root.localName == "html", root.uri == Self.xhtml,
                  let body = root.elements(forLocalName: "body", uri: Self.xhtml).first else { throw ImportFailure("an EPUB chapter has no XHTML body") }
            guard !xml.xmlString.contains(token) else { throw ImportFailure("an EPUB chapter conflicts with generated conversion markers") }
            documents[chapter.number] = xml; bodies[chapter.number] = body
            let chapterAnchor = "pmt-epub-chapter-\(chapter.number)"
            let boundary = token + "CHAPTER\(chapter.number)"
            markers[boundary] = chapterAnchor
            body.insertChild(XMLElement(name: "p", stringValue: boundary), at: 0)
            var ids: [String: String] = [:]
            for node in [root] + Self.elements(root) {
                guard let id = node.attribute(forName: "id")?.stringValue, !id.isEmpty else { continue }
                guard ids[id] == nil else { throw ImportFailure("an EPUB chapter has duplicate fragment identifiers") }
                if node === root || node === body { ids[id] = chapterAnchor; continue }
                guard Self.isInside(node, ancestor: body) else { continue }
                guard markers.count < 8_192 else { throw ImportFailure("selected EPUB chapters exceed 8192 fragment anchors") }
                serial += 1
                let anchor = chapterAnchor + "-anchor-\(serial)"
                let marker = token + "ANCHOR\(serial)"
                ids[id] = anchor; markers[marker] = anchor
                var position: XMLNode = node
                while let parent = position.parent as? XMLElement, !Self.anchorContainers.contains(parent.localName ?? "") { position = parent }
                guard let parent = position.parent as? XMLElement else { throw ImportFailure("an EPUB fragment has no safe anchor position") }
                parent.insertChild(XMLElement(name: "span", stringValue: marker), at: position.index)
            }
            ids[""] = chapterAnchor; anchors[chapter.path] = ids
        }
        for (completed, chapter) in chosen.enumerated() {
            try ConversionExecution.report(unit: .chapter, completed: completed, total: chosen.count)
            guard let xml = documents[chapter.number], let body = bodies[chapter.number] else { throw ImportFailure("the EPUB selection lost its staged chapter") }
            for node in Self.elements(body) where node.localName == "a" && node.uri == Self.xhtml {
                guard let attribute = node.attribute(forName: "href"), let href = attribute.stringValue else { continue }
                var parent = node.parent
                var isCode = false
                while let current = parent { if ["code", "pre"].contains(current.localName ?? "") { isCode = true; break }; parent = current.parent }
                if isCode { continue }
                guard linkTokens.count < 100_000 else { throw ImportFailure("selected EPUB chapters exceed 100000 internal links") }
                if let scheme = URLComponents(string: href)?.scheme, ["https", "http", "mailto"].contains(scheme.lowercased()) { continue }
                let pieces = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let target = pieces[0].isEmpty ? chapter.path : (try? ImportPackagePath.resolve(String(pieces[0]), relativeTo: chapter.path))
                let fragment = pieces.count == 2 ? String(pieces[1]).removingPercentEncoding : ""
                if let target, let fragment, let anchor = anchors[target]?[fragment] {
                    serial += 1; let link = token + "LINK\(serial)"; linkTokens[link] = anchor; attribute.stringValue = "#" + link
                } else {
                    node.removeAttribute(forName: "href")
                    let excluded = target.map { path in allPaths.contains(path) && anchors[path] == nil } ?? false
                    diagnosticStorage.append(.init(code: excluded ? "epub.linkTargetExcluded" : "epub.linkTargetUnavailable",
                        message: excluded ? "A link points to an excluded chapter; its visible text was retained without a dead link." : "An unsafe or missing EPUB link target was retained as visible text only.",
                        location: .init(chapter: chapter.number), kind: excluded ? .information : .contentLoss))
                }
            }
            try write(xml.xmlData(options: .nodeCompactEmptyElement), path: chapter.path, into: patch)
        }
        let selectedIDs = Set(chosen.map(\.id))
        for node in spine.elements(forLocalName: "itemref", uri: Self.opf).reversed() {
            if !selectedIDs.contains(node.attribute(forName: "idref")?.stringValue ?? "") { node.detach() }
            else {
                node.removeAttribute(forName: "linear")
                let attribute = XMLNode(kind: .attribute); attribute.name = "linear"; attribute.stringValue = "yes"; node.addAttribute(attribute)
            }
        }
        for node in Self.elements(document) {
            if node.localName == "meta", node.attribute(forName: "name")?.stringValue == "cover" { node.detach() }
            if let properties = node.attribute(forName: "properties"), let value = properties.stringValue {
                properties.stringValue = value.split(whereSeparator: \.isWhitespace).filter { $0 != "cover-image" }.joined(separator: " ")
            }
        }
        try write(document.xmlData(options: .nodeCompactEmptyElement), path: opfPath, into: patch)
        let paths = [opfPath] + chosen.map(\.path)
        for start in stride(from: 0, to: paths.count, by: 64) {
            let batch = Array(paths[start..<min(start + 64, paths.count)])
            let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/zip"), arguments: ["-q", "-0", archive.path, "-nw", "--"] + batch, currentDirectory: patch)
            guard result.status == 0 else { throw ImportFailure("the private EPUB selection could not be packaged: " + result.standardError) }
        }
        try ZIPArchiveInspector.withVerifiedReader(at: archive) { updated in
            guard updated.entryNames == reader.entryNames else { throw ImportFailure("the private EPUB selection changed its package entry names") }
        }
        try ConversionExecution.report(unit: .chapter, completed: chosen.count, total: chosen.count)
    }

    private static func isInside(_ node: XMLNode, ancestor: XMLNode) -> Bool {
        var parent = node.parent
        while let current = parent { if current === ancestor { return true }; parent = current.parent }
        return false
    }

    private func write(_ data: Data, path: String, into directory: URL) throws {
        let destination = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    func finishMarkdown(_ markdown: String) throws -> String {
        let targets = try MarkdownLinkTargetRewriter.resourceCandidates(in: markdown, maximum: 100_000, checking: ConversionExecution.check)
        var replacements = [String: String]()
        for target in targets {
            guard let range = target.range(of: token + "LINK"), let anchor = linkTokens[String(target[range.lowerBound...])] else { continue }
            replacements[target] = "#" + anchor
        }
        let linked = try MarkdownLinkTargetRewriter.replacing(in: markdown, mapping: replacements, checking: ConversionExecution.check)
        guard !linked.contains(token + "LINK") else { throw ImportFailure("an EPUB internal link could not be rebound") }
        let expression = try NSRegularExpression(pattern: token + "(?:CHAPTER|ANCHOR)[0-9]+")
        let source = linked as NSString
        let matches = expression.matches(in: linked, range: NSRange(location: 0, length: source.length))
        guard matches.count == markers.count else { throw ImportFailure("an EPUB conversion marker was lost or duplicated") }
        var seen = Set<String>(), cursor = 0, result = "", bytes = 0
        func append(_ text: String) throws {
            guard text.utf8.count <= 128 * 1_024 * 1_024 - bytes else { throw ImportFailure("selected EPUB Markdown exceeds 128 MiB") }
            bytes += text.utf8.count; result += text
        }
        for match in matches {
            try ConversionExecution.check()
            let marker = source.substring(with: match.range)
            guard seen.insert(marker).inserted, let anchor = markers[marker] else { throw ImportFailure("an EPUB conversion marker was lost or duplicated") }
            try append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            try append("<a id=\"\(anchor)\"></a>")
            cursor = NSMaxRange(match.range)
        }
        try append(source.substring(from: cursor))
        let data = Data(result.utf8)
        let positions = try chosen.map { chapter -> (Chapter, Int) in
            let anchor = Data("<a id=\"pmt-epub-chapter-\(chapter.number)\"></a>".utf8)
            guard let range = data.range(of: anchor) else { throw ImportFailure("an EPUB chapter boundary was lost") }
            return (chapter, range.lowerBound)
        }
        for (index, position) in positions.enumerated() {
            let end = index + 1 < positions.count ? positions[index + 1].1 : data.count
            guard end >= position.1 else { throw ImportFailure("the EPUB chapter order changed during conversion") }
            ConversionExecution.current?.recording?.record(.init(chapter: position.0.number), offset: position.1, length: end - position.1)
        }
        return result
    }
}
