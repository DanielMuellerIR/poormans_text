import Foundation

/// Gruppen folgen der ersten Diagnose; Nachrichten und bekannte Fundstellen
/// bleiben in ihrer ursprünglichen Reihenfolge und werden nicht erfunden.
public struct ConversionDiagnosticGroup: Codable, Hashable, Sendable {
    public let code: String
    public let kind: ConversionDiagnosticKind
    public let count: Int
    public let messages: [String]
    public let locations: [ConversionLocation]
    public let omittedCount: Int

    static func grouped(_ diagnostics: [ConversionWarning]) -> [Self] {
        struct Key: Hashable { let code: String; let kind: ConversionDiagnosticKind }
        var keys: [Key] = []
        var values: [Key: [ConversionWarning]] = [:]
        for warning in diagnostics {
            let key = Key(code: warning.code, kind: warning.kind)
            if values[key] == nil { keys.append(key) }
            values[key, default: []].append(warning)
        }
        return keys.map { key in
            let warnings = values[key]!
            var seenMessages = Set<String>(), seenLocations = Set<ConversionLocation>()
            return Self(code: key.code, kind: key.kind, count: warnings.count,
                        messages: warnings.compactMap { seenMessages.insert($0.message).inserted ? $0.message : nil },
                        locations: warnings.compactMap { warning in
                            guard let location = warning.location, seenLocations.insert(location).inserted else { return nil }
                            return location
                        }, omittedCount: warnings.reduce(0) { $0 + min($1.omittedCount ?? 0, Int.max - $0) })
        }
    }
}

struct BoundedConversionDiagnostics: Equatable {
    let maximumCount: Int
    private(set) var values: [ConversionWarning] = []
    private(set) var omittedCount = 0
    init(maximumCount: Int = 256) { self.maximumCount = max(0, maximumCount) }
    mutating func append(_ warning: ConversionWarning) {
        guard values.count < maximumCount else { addOmitted(warning.omittedCount ?? 1); return }
        values.append(warning)
    }
    mutating func addOmitted(_ count: Int) { omittedCount += min(max(0, count), Int.max - omittedCount) }
    var result: [ConversionWarning] {
        values + (omittedCount == 0 ? [] : [ConversionWarning(
            code: "diagnostics.limited", message: "\(omittedCount) further import diagnostics were omitted after the first \(maximumCount).",
            omittedCount: omittedCount)])
    }
}

struct ImportDiagnostics {
    private var diagnostics = BoundedConversionDiagnostics()
    var context: ConversionLocation?
    var values: [ConversionWarning] { diagnostics.values }
    mutating func add(_ code: String, _ message: String, page: Int? = nil, cell: String? = nil) {
        let known = ConversionLocation(page: page, cell: cell, slide: code.hasPrefix("presentation.") ? page : nil)
        let location = (context ?? ConversionLocation()).merging(known)
        diagnostics.append(ConversionWarning(code: code,
            message: message.count > 4_096 ? String(message.prefix(4_096)) + "…" : message,
            location: location == ConversionLocation() ? nil : location))
    }
    var result: [ConversionWarning] { diagnostics.result }
}
