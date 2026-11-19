import Foundation

public enum ReceiptOrigin: String, Codable, Sendable {
    case embeddedText, ocr
}

public struct ReceiptWord: Sendable {
    public let text: String
    public let rectangle: ReceiptRectangle
    public let line: Int
    public let origin: ReceiptOrigin

    public init(text: String, rectangle: ReceiptRectangle, line: Int, origin: ReceiptOrigin = .embeddedText) {
        self.text = text
        self.rectangle = rectangle
        self.line = line
        self.origin = origin
    }
}

public struct ReceiptPage: Sendable {
    public let pointsPerMillimeter: Double
    public let words: [ReceiptWord]

    public init(pointsPerMillimeter: Double, words: [ReceiptWord]) {
        self.pointsPerMillimeter = pointsPerMillimeter
        self.words = words
    }
}

public struct ReceiptDocument: Sendable {
    public let pages: [ReceiptPage]

    public init(pages: [ReceiptPage]) { self.pages = pages }
}

public struct ReceiptEvidence: Codable, Sendable {
    public let page: Int
    public let rectangle: ReceiptRectangle
    public let text: String
    public let origin: ReceiptOrigin
}

public enum ReceiptValueStatus: String, Codable, Sendable {
    case confirmed, corrected, missing, ambiguous

    public var needsReview: Bool { self == .missing || self == .ambiguous }
}

public struct ReceiptValue: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public fileprivate(set) var value: String?
    public fileprivate(set) var status: ReceiptValueStatus
    public let sources: [ReceiptEvidence]
    public fileprivate(set) var diagnostic: String?

    init(id: UUID, name: String, value: String?, status: ReceiptValueStatus,
         sources: [ReceiptEvidence], diagnostic: String?) {
        self.id = id
        self.name = name
        self.value = value
        self.status = status
        self.sources = sources
        self.diagnostic = diagnostic
    }
}

public struct ReceiptResult: Encodable, Sendable {
    public let partner: String
    public let documentType: String
    public private(set) var fields: [ReceiptValue]

    init(mask: ReceiptMask, fields: [ReceiptValue]) {
        self.partner = mask.partner
        self.documentType = mask.documentType
        self.fields = fields
    }

    public var needsReview: Bool { fields.contains { $0.status.needsReview } }

    /// Aktualisiert die Beschriftungen eines bereits mit denselben Regeln ausgewerteten Entwurfs.
    public func withMetadata(from mask: ReceiptMask) -> Self {
        let names = Dictionary(mask.fields.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let renamed = fields.map { field in
            ReceiptValue(id: field.id, name: names[field.id] ?? field.name, value: field.value,
                         status: field.status, sources: field.sources, diagnostic: field.diagnostic)
        }
        return Self(mask: mask, fields: renamed)
    }

    public mutating func correct(field: UUID, value: String) {
        guard let index = fields.firstIndex(where: { $0.id == field }) else { return }
        fields[index].value = value
        fields[index].status = .corrected
        fields[index].diagnostic = nil
    }

    public func write(to url: URL) throws {
        try ReceiptJSON.write(jsonData(), to: url)
    }

    public func jsonData() throws -> Data {
        var names = Set<String>()
        guard fields.allSatisfy({ names.insert($0.name).inserted }) else {
            throw ReceiptError.invalidMask("Field names must be unique before exporting.")
        }
        return try ReceiptJSON.encode(self)
    }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        try root.encode(1, forKey: .version)
        try root.encode(partner, forKey: .partner)
        try root.encode(documentType, forKey: .documentType)
        try root.encode(needsReview, forKey: .needsReview)
        var data = root.nestedContainer(keyedBy: FieldKey.self, forKey: .data)
        var sources = root.nestedContainer(keyedBy: FieldKey.self, forKey: .sources)
        var review = root.nestedContainer(keyedBy: FieldKey.self, forKey: .review)
        for field in fields {
            let key = FieldKey(stringValue: field.name)
            if let value = field.value { try data.encode(value, forKey: key) }
            else { try data.encodeNil(forKey: key) }
            try sources.encode(field.sources, forKey: key)
            try review.encode(Review(status: field.status, diagnostic: field.diagnostic), forKey: key)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, partner, documentType, needsReview, data, sources, review
    }

    private struct FieldKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct Review: Encodable {
        let status: ReceiptValueStatus
        let diagnostic: String?
    }
}
