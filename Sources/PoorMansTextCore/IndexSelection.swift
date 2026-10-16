import Foundation

/// Einsbasierte, inklusive Dokumentbereiche; Auflösung stets in Quellreihenfolge.
public struct IndexSelection: Codable, Hashable, Sendable, CustomStringConvertible {
    public let ranges: [ClosedRange<Int>]
    public static let maximumRangeCount = 1024
    public static let maximumResolvedCount = 1_000_000

    public init(_ expression: String) throws {
        guard expression.utf8.count <= 65_536 else { throw Failure("the selection expression is too long") }
        let fields = expression.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count <= Self.maximumRangeCount else { throw Failure("the selection contains too many ranges") }
        var ranges: [ClosedRange<Int>] = []
        func number(_ text: Substring) throws -> Int {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let result = Int(value), result > 0 else {
                throw Failure("selection positions must be positive integers")
            }
            return result
        }
        for field in fields {
            let bounds = field.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count) else { throw Failure("use positions or inclusive ranges, for example 1,3-5") }
            let lower = try number(bounds[0]), upper = try bounds.count == 2 ? number(bounds[1]) : lower
            guard lower <= upper else { throw Failure("a selection range must not run backwards") }
            ranges.append(lower...upper)
        }
        try self.init(ranges: ranges)
    }

    public init(ranges: [ClosedRange<Int>]) throws {
        guard !ranges.isEmpty else { throw Failure("the selection must not be empty") }
        guard ranges.count <= Self.maximumRangeCount else { throw Failure("the selection contains too many ranges") }
        guard ranges.allSatisfy({ $0.lowerBound > 0 }) else { throw Failure("selection positions must be positive integers") }
        var normalized: [ClosedRange<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound }) {
            if let last = normalized.last, range.lowerBound <= last.upperBound
                || (last.upperBound < Int.max && range.lowerBound == last.upperBound + 1) {
                normalized[normalized.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { normalized.append(range) }
        }
        self.ranges = normalized
    }

    public var description: String {
        ranges.map { $0.lowerBound == $0.upperBound ? String($0.lowerBound) : "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
    }

    public func zeroBasedIndices(itemCount: Int) throws -> [Int] {
        guard itemCount > 0 else { throw Failure("the document contains no selectable positions") }
        var indices: [Int] = []
        for range in ranges {
            guard range.upperBound <= itemCount else { throw Failure("selection position \(range.upperBound) exceeds the document count \(itemCount)") }
            guard range.upperBound - range.lowerBound < Self.maximumResolvedCount - indices.count else {
                throw Failure("the resolved selection exceeds its item limit")
            }
            indices.append(contentsOf: range.map { $0 - 1 })
        }
        return indices
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let expression = try container.decode(String.self)
        do { try self.init(expression) }
        catch { throw DecodingError.dataCorruptedError(in: container, debugDescription: error.localizedDescription) }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(description)
    }
    public struct Failure: LocalizedError, Sendable {
        public let reason: String
        init(_ reason: String) { self.reason = reason }
        public var errorDescription: String? { reason }
    }
}
