import Foundation

public struct PresentationSelection: Codable, Hashable, Sendable {
    public let slides: IndexSelection?
    public let includeNotes: Bool
    public init(slides: IndexSelection? = nil, includeNotes: Bool = true) {
        self.slides = slides
        self.includeNotes = includeNotes
    }
}

public struct PresentationSlideSummary: Codable, Hashable, Sendable {
    public let number: Int
    public let title: String?
    public let hasNotes: Bool
}

public struct PresentationContentSummary: Codable, Sendable {
    public let sourceIdentity: ConversionSourceIdentity
    public let slideCount: Int
    public let slides: [PresentationSlideSummary]
    public let slidesTruncated: Bool
    public static let maximumSummarySlides = 500
}
