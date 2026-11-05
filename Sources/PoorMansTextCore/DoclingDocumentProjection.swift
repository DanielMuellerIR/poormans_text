import Foundation

// Nur Projektion gespeicherter Erkennungsdaten. Snapshotbindung, Assets und
// Modell-/Prozessfreigabe müssen vor einem Produktaufruf separat erfüllt sein.
enum DoclingDocumentProjection {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    private static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw Failure(reason: reason) }
    }
    private struct Ref: Decodable {
        let value: String
        enum CodingKeys: String, CodingKey { case value = "$ref" }
    }
    private struct Box: Decodable {
        enum CodingKeys: String, CodingKey {
            case l
            case t
            case r
            case b
            case coordOrigin = "coord_origin"
        }
        let l: Double
        let t: Double
        let r: Double
        let b: Double
        let coordOrigin: String
        func normalized(width: Double, height: Double) throws -> CGRect {
            try require([l, t, r, b].allSatisfy(\.isFinite), "nonfinite rectangle")
            try require(l >= 0 && r > l && r <= width, "rectangle x bounds")
            let bottom: Double
            let top: Double
            switch coordOrigin {
            case "BOTTOMLEFT":
                bottom = b
                top = t
            case "TOPLEFT":
                bottom = height - b
                top = height - t
            default: throw Failure(reason: "unknown coordinate origin")
            }
            try require(bottom >= 0 && top > bottom && top <= height, "rectangle y bounds")
            return CGRect(
                x: l / width, y: bottom / height, width: (r - l) / width,
                height: (top - bottom) / height)
        }
    }
    private struct Provenance: Decodable {
        enum CodingKeys: String, CodingKey {
            case pageNo = "page_no"
            case bbox
            case charspan
        }
        let pageNo: Int
        let bbox: Box
        let charspan: [Int]
    }
    private struct Cell: Decodable {
        enum CodingKeys: String, CodingKey {
            case bbox
            case rowSpan = "row_span"
            case colSpan = "col_span"
            case startRowOffsetIdx = "start_row_offset_idx"
            case endRowOffsetIdx = "end_row_offset_idx"
            case startColOffsetIdx = "start_col_offset_idx"
            case endColOffsetIdx = "end_col_offset_idx"
            case text
        }
        let bbox: Box
        let rowSpan: Int
        let colSpan: Int
        let startRowOffsetIdx: Int
        let endRowOffsetIdx: Int
        let startColOffsetIdx: Int
        let endColOffsetIdx: Int
        let text: String
    }
    // grid ist absichtlich nicht im DTO: Es wiederholt Spanzellen.
    private struct Table: Decodable {
        enum CodingKeys: String, CodingKey {
            case tableCells = "table_cells"
            case numRows = "num_rows"
            case numCols = "num_cols"
        }
        let tableCells: [Cell]
        let numRows: Int
        let numCols: Int
    }
    private struct Node: Decodable {
        enum CodingKeys: String, CodingKey {
            case selfRef = "self_ref"
            case parent
            case children
            case label
            case contentLayer = "content_layer"
            case prov
            case text
            case orig
            case marker
            case data
            case captions
            case references
            case footnotes
        }
        let selfRef: String
        let parent: Ref?
        let children: [Ref]
        let label: String
        let contentLayer: String
        let prov: [Provenance]?
        let text: String?
        let orig: String?
        let marker: String?
        let data: Table?
        let captions: [Ref]?
        let references: [Ref]?
        let footnotes: [Ref]?
    }
    private struct Size: Decodable {
        let width: Double
        let height: Double
    }
    private struct Page: Decodable {
        enum CodingKeys: String, CodingKey {
            case size
            case pageNo = "page_no"
        }
        let size: Size
        let pageNo: Int
    }
    private struct UnsupportedItem: Decodable {}
    private struct Root: Decodable {
        enum CodingKeys: String, CodingKey {
            case schemaName = "schema_name"
            case version
            case body
            case furniture
            case groups
            case texts
            case pictures
            case tables
            case pages
            case keyValueItems = "key_value_items"
            case formItems = "form_items"
        }
        let schemaName: String
        let version: String
        let body: Node
        let furniture: Node
        let groups: [Node]
        let texts: [Node]
        let pictures: [Node]
        let tables: [Node]
        let pages: [String: Page]
        let keyValueItems: [UnsupportedItem]
        let formItems: [UnsupportedItem]
    }
    struct Item: Codable {
        let ref: String
        let label: String
        let layer: String
        let text: String
        let orig: String?
        let alternateText: String?
        let normalizedBounds: [Double]
    }
    struct Result {
        let recognition: StructuredDocumentRecognition
        let items: [Item]
        let rawCellCount: Int
        let pictureRefs: [String]
        let schema: String
    }
    static func scalarFragments(original: String, alternate: String, spans: [[Int]]) throws
        -> [String]
    {
        try require(
            original.utf8.count <= 1_000_000 && !spans.isEmpty && spans.count <= 1024,
            "fragment budget or missing provenance")
        let scalars = Array(original.unicodeScalars)
        if !original.utf8.elementsEqual(alternate.utf8) {
            try require(
                spans.count == 1 && spans[0] == [0, scalars.count]
                    && scalars.count > alternate.unicodeScalars.count,
                "ambiguous provenance text basis")
        }
        var cursor = 0
        var result = [String]()
        for span in spans {
            try require(
                span.count == 2 && span[0] >= cursor && span[1] > span[0]
                    && span[1] <= scalars.count,
                "overlapping or out-of-range provenance spans")
            try require(
                scalars[cursor..<span[0]].allSatisfy {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                },
                "uncovered nonwhitespace text")
            result.append(String(String.UnicodeScalarView(scalars[span[0]..<span[1]])))
            cursor = span[1]
        }
        try require(
            scalars[cursor...].allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) },
            "uncovered trailing text")
        return result
    }
    static func parse(_ data: Data) throws -> Result {
        try ConversionExecution.check()
        try require(data.count <= 8 * 1024 * 1024, "JSON byte budget")
        try JSONStructurePreflight.validate(
            data, limits: .init(depth: 32, nodes: 250_000, keyBytes: 256), documentName: "Docling")
        let decoder = JSONDecoder()
        let root = try decoder.decode(Root.self, from: data)
        try require(
            root.schemaName == "DoclingDocument" && root.version == "1.11.0", "unsupported schema")
        try require(
            root.keyValueItems.isEmpty && root.formItems.isEmpty,
            "unsupported form or key-value nodes")
        try require(
            root.pages.count == 1 && root.pages["1"]?.pageNo == 1,
            "projection requires exactly page 1"
        )
        let page = root.pages["1"]!
        let w = page.size.width
        let h = page.size.height
        try require(
            w.isFinite && h.isFinite && w > 0 && h > 0 && w <= 1_000_000 && h <= 1_000_000,
            "page dimensions")
        try require(
            root.groups.count + root.texts.count + root.pictures.count + root.tables.count
                <= 10_000,
            "node count")
        var nodes: [String: Node] = [:]
        func add(_ node: Node, _ expected: String) throws {
            try require(node.selfRef == expected && nodes[expected] == nil, "node identity")
            try require(
                ["body", "furniture"].contains(node.contentLayer), "unsupported content layer")
            nodes[expected] = node
        }
        try add(root.body, "#/body")
        try add(root.furniture, "#/furniture")
        for (prefix, values) in [
            ("groups", root.groups), ("texts", root.texts), ("pictures", root.pictures),
            ("tables", root.tables),
        ] {
            for (i, node) in values.enumerated() { try add(node, "#/\(prefix)/\(i)") }
        }
        var order = [String]()
        var active = Set<String>()
        var seen = Set<String>()
        func walk(_ ref: String, parent: String?, depth: Int) throws {
            try require(depth <= 32, "reference depth")
            guard let node = nodes[ref] else { throw Failure(reason: "missing reference \(ref)") }
            try require(
                !active.contains(ref) && seen.insert(ref).inserted,
                "cyclic or duplicate structural reference")
            try require(node.parent?.value == parent, "parent reference mismatch")
            active.insert(ref)
            order.append(ref)
            for child in node.children { try walk(child.value, parent: ref, depth: depth + 1) }
            active.remove(ref)
            for alias in (node.captions ?? []) + (node.references ?? []) + (node.footnotes ?? []) {
                try require(nodes[alias.value] != nil, "missing alias reference \(alias.value)")
            }
        }
        try walk("#/body", parent: nil, depth: 0)
        try walk("#/furniture", parent: nil, depth: 0)
        try require(seen.count == nodes.count, "unreachable node")
        var paragraphs = [StructuredDocumentRecognition.Text]()
        var tables = [StructuredDocumentRecognition.Table]()
        var items = [Item]()
        var cellCount = 0
        var textBytes = 0
        var pictures = [String]()
        var tableSlots = 0
        func append(
            _ text: String, box: CGRect, ref: String, label: String, layer: String,
            orig: String? = nil,
            alternate: String? = nil
        ) throws {
            try require(
                text.utf8.count <= 1_000_000 && text.utf8.count <= 8_000_000 - textBytes,
                "text budget")
            textBytes += text.utf8.count
            paragraphs.append(.init(text: text, bounds: box))
            items.append(
                Item(
                    ref: ref, label: label, layer: layer, text: text, orig: orig,
                    alternateText: alternate,
                    normalizedBounds: [box.minX, box.minY, box.width, box.height]))
        }
        func box(_ node: Node) throws -> CGRect {
            guard let p = node.prov, p.count == 1 else {
                throw Failure(reason: "missing or fragmented provenance")
            }
            try require(
                p[0].pageNo == 1 && p[0].charspan.count == 2 && p[0].charspan[0] >= 0
                    && p[0].charspan[1] >= p[0].charspan[0], "provenance page or span")
            let textLength = node.orig?.unicodeScalars.count ?? node.text?.unicodeScalars.count ?? 0
            try require(p[0].charspan[1] <= textLength, "provenance character span")
            return try p[0].bbox.normalized(width: w, height: h)
        }
        for ref in order {
            try ConversionExecution.check()
            let node = nodes[ref]!
            if ref.hasPrefix("#/texts/") {
                try require(node.data == nil, "unsupported table data on text node")
                guard let original = node.orig, let alternate = node.text else {
                    throw Failure(reason: "missing text representation")
                }
                if let marker = node.marker, !marker.isEmpty {
                    try require(marker.utf8.count <= 256 && original.utf8.starts(with: marker.utf8),
                                "unprojected list marker")
                }
                guard let provenance = node.prov else {
                    throw Failure(reason: "missing provenance")
                }
                let fragments = try scalarFragments(
                    original: original, alternate: alternate, spans: provenance.map(\.charspan))
                for (i, p) in provenance.enumerated() {
                    try require(p.pageNo == 1, "fragment page")
                    let bounds = try p.bbox.normalized(width: w, height: h)
                    let source = provenance.count == 1 ? ref : ref + "/prov/\(i)"
                    try append(
                        fragments[i], box: bounds, ref: source, label: node.label,
                        layer: node.contentLayer,
                        orig: original, alternate: alternate)
                }
            } else if ref.hasPrefix("#/tables/") {
                try require(node.text == nil && node.orig == nil, "unprojected table text")
                guard let data = node.data else { throw Failure(reason: "missing table data") }
                try require(
                    data.numRows > 0 && data.numCols > 0 && data.numCols <= 256
                        && data.numRows <= 4096 / data.numCols, "table dimensions")
                try require(
                    !data.tableCells.isEmpty && data.tableCells.count <= 4096, "table cell count")
                try require(
                    data.numRows * data.numCols <= 4096 - tableSlots, "aggregate table slot budget")
                tableSlots += data.numRows * data.numCols
                let bounds = try box(node)
                var occupied = Set<Int>()
                var projected = [StructuredDocumentRecognition.Table.Cell]()
                for (i, c) in data.tableCells.enumerated() {
                    try ConversionExecution.check()
                    let rs = c.startRowOffsetIdx
                    let re = c.endRowOffsetIdx
                    let cs = c.startColOffsetIdx
                    let ce = c.endColOffsetIdx
                    try require(
                        rs >= 0 && cs >= 0 && re > rs && ce > cs && re <= data.numRows
                            && ce <= data.numCols,
                        "cell range")
                    try require(c.rowSpan == re - rs && c.colSpan == ce - cs, "cell span mismatch")
                    for row in rs..<re {
                        for column in cs..<ce {
                            try require(
                                occupied.insert(row * data.numCols + column).inserted,
                                "overlapping cells")
                        }
                    }
                    let rect = try c.bbox.normalized(width: w, height: h)
                    // CGRect.contains(CGRect) vergleicht unter Linux die gerundete
                    // Schnittmenge; direkte Kantenvergleiche brauchen keine Toleranz.
                    try require(
                        rect.minX >= bounds.minX && rect.maxX <= bounds.maxX
                            && rect.minY >= bounds.minY && rect.maxY <= bounds.maxY,
                        "cell outside table")
                    let value = StructuredDocumentRecognition.Text(text: c.text, bounds: rect)
                    projected.append(
                        .init(rows: rs...(re - 1), columns: cs...(ce - 1), text: value))
                    try append(
                        c.text, box: rect, ref: ref + "/data/table_cells/\(i)", label: "table_cell",
                        layer: node.contentLayer)
                    cellCount += 1
                }
                try require(occupied.count == data.numRows * data.numCols, "missing table coverage")
                tables.append(.init(bounds: bounds, cells: projected))
            } else if ref.hasPrefix("#/pictures/") {
                try require(
                    node.text == nil && node.orig == nil && node.data == nil,
                    "unsupported picture text or table data")
                _ = try box(node)
                pictures.append(ref)
            } else {
                try require(
                    node.text == nil && node.orig == nil && node.data == nil,
                    "unprojected container content")
            }
        }
        try require(!paragraphs.isEmpty, "empty text authority")
        let document = StructuredDocumentRecognition.Document(
            text: .init(
                text: paragraphs.map(\.text).joined(separator: "\n"),
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1)), paragraphs: paragraphs, lists: [],
            tables: tables)
        return Result(
            recognition: .init(documents: [document], languages: []), items: items,
            rawCellCount: cellCount, pictureRefs: pictures, schema: root.version)
    }
}
