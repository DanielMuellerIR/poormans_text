import Foundation

public struct PDFPageSummary: Codable, Hashable, Sendable {
    public let number: Int
    public let label: String?
    public let width: Double?
    public let height: Double?
}

/// Begrenzte Seitenmetadaten; weder Textextraktion noch OCR oder Veröffentlichung.
public struct PDFContentSummary: Codable, Sendable {
    public let sourceIdentity: ConversionSourceIdentity
    public let pageCount: Int
    public let pages: [PDFPageSummary]
    public let pagesTruncated: Bool
    public static let maximumSummaryPages = 500
}
