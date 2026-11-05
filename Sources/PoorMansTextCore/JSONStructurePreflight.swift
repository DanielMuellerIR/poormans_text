import Foundation

// Foundation kann doppelte oder Unicode-kanonisch gleiche Schlüssel bereits
// beim Decodieren zusammenfassen. Vorher prüfen, damit keine Inhalte verschwinden.
struct JSONStructurePreflight {
    struct Limits {
        let depth: Int
        let nodes: Int
        let keyBytes: Int
    }
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    private let limits: Limits
    private let documentName: String
    private let bytes: [UInt8]
    private var index = 0
    private var nodes = 0
    static func validate(_ data: Data, limits: Limits, documentName: String) throws {
        var scanner = Self(limits: limits, documentName: documentName, bytes: Array(data))
        try scanner.value(depth: 0); scanner.space()
        guard scanner.index == scanner.bytes.count else { throw Failure(reason: "The \(documentName) JSON has trailing content.") }
    }
    private mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    private mutating func string() throws -> Range<Int> {
        guard index < bytes.count, bytes[index] == 34 else { throw Failure(reason: "The \(documentName) JSON has a malformed key or string.") }
        let start = index; index += 1
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 { return start..<index }
            if byte == 92 { index += 1 }
        }
        throw Failure(reason: "The \(documentName) JSON contains an incomplete string.")
    }
    private mutating func value(depth: Int) throws {
        nodes += 1; space()
        guard depth <= limits.depth, nodes <= limits.nodes, index < bytes.count else { throw Failure(reason: "The \(documentName) JSON exceeds its structure limit or is incomplete.") }
        if bytes[index] == 34 { _ = try string(); return }
        if bytes[index] == 123 || bytes[index] == 91 {
            let object = bytes[index] == 123, end: UInt8 = object ? 125 : 93
            index += 1; space()
            if index < bytes.count, bytes[index] == end { index += 1; return }
            var keys = Set<String>()
            while index < bytes.count {
                if object {
                    let range = try string()
                    let key: String
                    do { key = try JSONDecoder().decode(String.self, from: Data(bytes[range])) }
                    catch { throw Failure(reason: "The \(documentName) JSON contains an invalid key.") }
                    guard key.utf8.count <= limits.keyBytes, keys.insert(key).inserted else { throw Failure(reason: "The \(documentName) JSON contains duplicate or overlong keys.") }
                    space()
                    guard index < bytes.count, bytes[index] == 58 else { throw Failure(reason: "The \(documentName) JSON is missing a field separator.") }
                    index += 1
                }
                try value(depth: depth + 1); space()
                guard index < bytes.count else { break }
                if bytes[index] == end { index += 1; return }
                guard bytes[index] == 44 else { throw Failure(reason: "The \(documentName) JSON is missing an item separator.") }
                index += 1; space()
            }
            throw Failure(reason: "The \(documentName) JSON contains an incomplete object or array.")
        }
        let start = index
        while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
        guard index > start else { throw Failure(reason: "The \(documentName) JSON contains a missing value.") }
    }
}
