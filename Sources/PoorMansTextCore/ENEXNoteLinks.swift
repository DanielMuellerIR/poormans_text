import Foundation

struct ENEXNoteLinks {
    enum Resolution {
        case external
        case resolved(String)
        case unavailable(ConversionWarning)
    }
    private let indices: [String: [Int]]
    let warnings: [Int: [ConversionWarning]]

    init(notes: [ENEXReader.Note]) {
        var indices: [String: [Int]] = [:]
        var warnings: [Int: [ConversionWarning]] = [:]
        for note in notes {
            // Standard-ENEX lässt GUIDs oft weg. Nur explizite Identitätsfelder
            // sind ein Beleg; Titel und Linkbeschriftungen sind keiner.
            let nodes = note.node.elements("guid", namespace: "")
            let declared = ([note.node.attribute("guid")].compactMap { $0 } + nodes.map(\.text))
            guard !declared.isEmpty else { continue }
            let values = declared.compactMap(Self.guid)
            guard nodes.allSatisfy({ $0.children.isEmpty }), values.count == declared.count, Set(values).count == 1 else {
                warnings[note.index, default: []].append(.init(code: "enex.noteIdentityInvalid", message: "An exported note identity is invalid or conflicting; it was not used for internal links.", kind: .approximation))
                continue
            }
            indices[values[0], default: []].append(note.index)
        }
        for values in indices.values where values.count > 1 {
            for index in values {
                warnings[index, default: []].append(.init(code: "enex.noteIdentityAmbiguous", message: "An exported note identity occurs more than once; its internal link targets are ambiguous.", kind: .approximation))
            }
        }
        self.indices = indices
        self.warnings = warnings
    }

    func resolve(_ target: String, markdownName: String) -> Resolution {
        if let url = URLComponents(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           ["evernote.com", "www.evernote.com"].contains(url.host?.lowercased() ?? ""), url.path.hasPrefix("/l/") {
            return .unavailable(.init(code: "enex.internalLinkUnresolved", message: "A shortened Evernote link has no offline target identity and was retained as text.", kind: .approximation))
        }
        let parsed = Self.targetGUID(target)
        guard parsed.internalLink else { return .external }
        guard let guid = parsed.guid else {
            return .unavailable(.init(code: "enex.internalLinkInvalid", message: "An internal Evernote link has an invalid or conflicting identity and was retained as text.", kind: .approximation))
        }
        guard let values = indices[guid], !values.isEmpty else {
            return .unavailable(.init(code: "enex.internalLinkUnresolved", message: "The target identity of an internal Evernote link is absent from this export; its text and original target were retained.", kind: .approximation))
        }
        guard values.count == 1 else {
            return .unavailable(.init(code: "enex.internalLinkAmbiguous", message: "The target identity of an internal Evernote link is not unique in this export; its text and original target were retained.", kind: .approximation))
        }
        let path = "../" + String(format: "%06d", values[0]) + "/" + markdownName
        return .resolved(MarkdownLinkTargetRewriter.percentEncodedPath(path))
    }

    static func guid(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil else { return nil }
        return value.lowercased()
    }

    private static func targetGUID(_ target: String) -> (internalLink: Bool, guid: String?) {
        guard let url = URLComponents(string: target) else { return (target.lowercased().hasPrefix("evernote:"), nil) }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let classic = scheme == "evernote"
        let web = ["http", "https"].contains(scheme) && ["evernote.com", "www.evernote.com"].contains(host) && url.path.hasPrefix("/shard/")
        guard classic || web else { return (false, nil) }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath == url.path,
              !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return (true, nil) }
        let fields = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if classic {
            guard host.isEmpty, url.port == nil, fields.count == 5 || fields.count == 6, fields[0] == "view",
                  fields[1].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                  fields[2].range(of: #"^s[0-9]+$"#, options: .regularExpression) != nil,
                  let first = guid(fields[3]), first == guid(fields[4]),
                  fields.count == 5 || guid(fields[5]) != nil else { return (true, nil) }
            return (true, first)
        }
        guard url.port == nil || url.port == (scheme == "https" ? 443 : 80), fields.count == 5,
              fields[0] == "shard", fields[1].range(of: #"^s[0-9]+$"#, options: .regularExpression) != nil else { return (true, nil) }
        if fields[2] == "nl", fields[3].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil { return (true, guid(fields[4])) }
        if fields[2] == "sh", !fields[4].isEmpty { return (true, guid(fields[3])) }
        return (true, nil)
    }
}
