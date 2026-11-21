import Foundation

public struct ReceiptRectangle: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rectangle: CGRect) {
        self.init(x: rectangle.minX, y: rectangle.minY, width: rectangle.width, height: rectangle.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    var isValid: Bool {
        [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

public enum ReceiptValueKind: String, Codable, Sendable {
    case date, identifier
}

public enum ReceiptRule: Codable, Hashable, Sendable {
    case region(page: Int, rectangle: ReceiptRectangle)
    case rightOf(label: String, kind: ReceiptValueKind)
}

public struct ReceiptField: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var rule: ReceiptRule

    public init(id: UUID = UUID(), name: String, rule: ReceiptRule) {
        self.id = id
        self.name = name
        self.rule = rule
    }
}

public struct ReceiptMask: Codable, Hashable, Sendable {
    public static let maximumFields = 500
    private static let maximumBytes = 1_000_000
    public let version: Int
    public var partner: String
    public var documentType: String
    public var fields: [ReceiptField]

    public init(partner: String = "", documentType: String = "", fields: [ReceiptField] = []) {
        self.version = 1
        self.partner = partner
        self.documentType = documentType
        self.fields = fields
    }

    public static func load(from url: URL) throws -> Self {
        let failure = ReceiptError.invalidMask("The mask must be a readable JSON file of at most 1 MB.")
        let data = try VerifiedFile.open(at: url, failure: { _ in failure }) { file in
            guard file.isRegularFile else { throw failure }
            var data = Data()
            _ = try file.readChunks(
                maximumBytes: maximumBytes, chunkSize: 64 * 1024, budgetExceeded: { failure }
            ) {
                data.append(contentsOf: $0)
                return true
            }
            return data
        }
        let mask: Self
        do {
            try JSONStructurePreflight.validate(
                data, limits: .init(depth: 16, nodes: 20_000, keyBytes: 128), documentName: "mask")
            mask = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ReceiptError.invalidMask("Invalid mask JSON: \(error.localizedDescription)")
        }
        try mask.validate()
        return mask
    }

    public func save(to url: URL) throws {
        try validate()
        let data = try ReceiptJSON.encode(self)
        guard data.count <= Self.maximumBytes else {
            throw ReceiptError.invalidMask("The mask exceeds the 1 MB JSON size limit.")
        }
        try ReceiptJSON.write(data, to: url)
    }

    func validate() throws {
        guard version == 1 else {
            throw ReceiptError.invalidMask("Unsupported mask version \(version).")
        }
        guard Self.validName(partner), Self.validName(documentType),
            (1...Self.maximumFields).contains(fields.count)
        else {
            throw ReceiptError.invalidMask("Enter a partner, a document type and between one and 500 fields.")
        }
        var names = Set<String>()
        var ids = Set<UUID>()
        for field in fields {
            guard Self.validName(field.name), names.insert(field.name).inserted, ids.insert(field.id).inserted
            else {
                throw ReceiptError.invalidMask("Field names must be nonempty and unique.")
            }
            switch field.rule {
            case let .region(page, rectangle):
                guard (0..<ReceiptPDF.maximumPages).contains(page), rectangle.isValid else {
                    throw ReceiptError.invalidMask("Invalid selection for \(field.name).")
                }
            case let .rightOf(label, _):
                guard Self.validName(label) else {
                    throw ReceiptError.invalidMask("Missing label for \(field.name).")
                }
            }
        }
    }

    private static func validName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value == trimmed && value.utf8.count <= 512
    }
}

public enum ReceiptError: LocalizedError, Sendable {
    case invalidMask(String)
    case invalidDocument(String)
    case invalidOutputDirectory(URL)
    case outputConflict(URL)

    public var errorDescription: String? {
        switch self {
        case let .invalidMask(message), let .invalidDocument(message):
            return message
        case let .invalidOutputDirectory(url):
            return "Output directory is unavailable: \(url.path)"
        case let .outputConflict(url):
            return "Output name is already in use: \(url.path)"
        }
    }
}
