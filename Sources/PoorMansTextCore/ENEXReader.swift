import Foundation

enum ENEXReader {
    static let maximumSourceBytes = 16 * 1_048_576
    static let maximumContentBytes = 8 * 1_048_576

    struct Note {
        let index: Int
        let title: String
        let content: String
        let node: ImportXML
        let metadata: DocumentMetadata
        let warnings: [ConversionWarning]
    }
    struct Archive {
        let notes: [Note]
        let fields: [String: String]
    }

    static func read(_ data: Data) throws -> Archive {
        guard data.count <= maximumSourceBytes, let source = String(data: data, encoding: .utf8) else {
            throw ImportFailure("the ENEX is not UTF-8 or exceeds its 16 MiB size limit")
        }
        let root = try ENEXXML.parse(source, root: "en-export")
        guard Set(root.attributes.keys).isSubset(of: ["|export-date", "|application", "|version"]),
              root.children.allSatisfy({ $0.name == "note" && $0.namespace.isEmpty }), root.children.count <= CollectionLimits.maximumDocuments,
              root.content.allSatisfy({ if case .text(let value) = $0 { return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return true }) else {
            throw ImportFailure("the ENEX contains unexpected root content or exceeds its note limit")
        }
        var notes: [Note] = []
        for (offset, node) in root.children.enumerated() {
            try ConversionExecution.check()
            guard node.content.allSatisfy({ if case .text(let value) = $0 { return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return true }) else {
                throw ImportFailure("an ENEX note contains text outside its fields")
            }
            let rawTitle = try field("title", in: node) ?? ""
            guard rawTitle.utf8.count <= CollectionLimits.maximumTitleBytes,
                  !rawTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ImportFailure("an ENEX title is invalid or exceeds its size limit") }
            guard let contentNode = try single("content", in: node), contentNode.children.isEmpty else { throw ImportFailure("an ENEX note must contain one textual ENML content field") }
            let content = contentNode.text
            guard content.utf8.count <= maximumContentBytes,
                  node.elements("tag", namespace: "").count <= 1024,
                  node.elements("tag", namespace: "").allSatisfy({ $0.children.isEmpty }),
                  node.elements("task", namespace: "").count <= 1024 else { throw ImportFailure("an ENEX note exceeds its content, tag or task limit") }
            var warnings: [ConversionWarning] = []
            func date(_ name: String) throws -> Date? {
                guard let raw = try field(name, in: node) else { return nil }
                if let parsed = parsedDate(raw) { return parsed }
                warnings.append(.init(code: "enex.invalidDate", message: "An invalid ENEX date was retained as source text: " + name, kind: .approximation))
                return nil
            }
            let attributes = try single("note-attributes", in: node)
            let metadata = try DocumentMetadata(title: rawTitle, author: attributes.flatMap { try field("author", in: $0) },
                keywords: node.elements("tag", namespace: "").map(\.text), created: date("created"), modified: date("updated"))
            guard try JSONEncoder().encode(metadata).count <= CollectionLimits.maximumDocumentMetadataBytes else { throw ImportFailure("ENEX note metadata exceeds its size limit") }
            notes.append(.init(index: offset + 1, title: rawTitle.isEmpty ? "Note \(offset + 1)" : rawTitle,
                content: content, node: node, metadata: metadata, warnings: warnings))
        }
        return Archive(notes: notes, fields: root.attributes)
    }

    static func single(_ name: String, in node: ImportXML) throws -> ImportXML? {
        let values = node.elements(name, namespace: "")
        guard values.count <= 1 else { throw ImportFailure("an ENEX field occurs more than once: " + name) }
        return values.first
    }
    static func field(_ name: String, in node: ImportXML) throws -> String? {
        guard let value = try single(name, in: node) else { return nil }
        guard value.children.isEmpty else { throw ImportFailure("an ENEX scalar field contains nested elements: " + name) }
        return value.text
    }
    static func parsedDate(_ raw: String) -> Date? {
        guard raw.range(of: #"^[0-9]{8}T[0-9]{6}Z$"#, options: .regularExpression) != nil, Int(raw.prefix(4)) != 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
        return date
    }
}
