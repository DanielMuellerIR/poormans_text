import Foundation
import PoorMansTextCore

public struct ComparisonTarget: Equatable, Sendable {
    public let range: ConversionTextRange
    public let exact: Bool
}

public struct ComparisonSection: Identifiable, Hashable, Sendable {
    public let location: ConversionLocation
    public var id: ConversionLocation { location }
    public var label: String { ComparisonNavigation.label(location) }
}

public enum ComparisonNavigation {
    public static func label(_ location: ConversionLocation?) -> String {
        guard let original = location else { return NSLocalizedString("Unknown location", comment: "") }
        let location = normalized(original)
        let parts = [
            location.page.flatMap { location.frame == $0 ? nil : String(format: NSLocalizedString("Page %d", comment: ""), $0) },
            location.frame.map { String(format: NSLocalizedString("Frame %d", comment: ""), $0) },
            location.sheet.map { String(format: NSLocalizedString("Sheet %@", comment: ""), $0) },
            location.cell.map { String(format: NSLocalizedString("Cell %@", comment: ""), $0) },
            location.chapter.map { String(format: NSLocalizedString("Chapter %d", comment: ""), $0) },
            location.slide.map { String(format: NSLocalizedString("Slide %d", comment: ""), $0) },
            location.paragraph.map { String(format: NSLocalizedString("Paragraph %d", comment: ""), $0) },
            location.message.map { String(format: NSLocalizedString("Message %@", comment: ""), $0) },
            location.note.map { String(format: NSLocalizedString("Note %@", comment: ""), $0) },
        ].compactMap { $0 }
        return parts.isEmpty ? NSLocalizedString("Unknown location", comment: "") : parts.joined(separator: ", ")
    }

    public static func kindLabel(_ kind: ConversionDiagnosticKind) -> String {
        switch kind {
        case .information: NSLocalizedString("Information", comment: "")
        case .approximation: NSLocalizedString("Approximation", comment: "")
        case .contentLoss: NSLocalizedString("Content loss", comment: "")
        }
    }

    public static func matches(_ warning: ConversionWarning, kind: ConversionDiagnosticKind?, locationQuery: String) -> Bool {
        guard kind == nil || warning.kind == kind else { return false }
        let query = locationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || label(warning.location).localizedStandardContains(query)
    }

    public static func sections(_ mappings: [ConversionSourceMapping], limit: Int = 2048) -> [ComparisonSection] {
        var seen = Set<ConversionLocation>()
        var result: [ComparisonSection] = []
        for mapping in mappings {
            let source = normalized(mapping.source)
            let location = ConversionLocation(page: source.page, sheet: source.sheet, sheetIndex: source.sheetIndex, slide: source.slide, frame: source.frame,
                                              message: source.message, note: source.note, chapter: source.chapter)
            guard location != ConversionLocation(), seen.insert(location).inserted else { continue }
            guard result.count < limit else { break }
            result.append(ComparisonSection(location: location))
        }
        return result
    }

    public static func target(for location: ConversionLocation?, mappings: [ConversionSourceMapping]) -> ComparisonTarget? {
        guard let original = location, original != ConversionLocation() else { return nil }
        let location = normalized(original)
        let direct = mappings.filter { includes(normalized($0.source), requested: location) }
        guard sections(direct, limit: 2).count <= 1 else { return nil }
        if let first = direct.first {
            return ComparisonTarget(range: first.output, exact: sameDetail(normalized(first.source), requested: location))
        }
        let hasVisualSection = location.page != nil || location.sheet != nil || location.slide != nil || location.frame != nil || location.chapter != nil
        let section = ConversionLocation(page: location.page, sheet: location.sheet, sheetIndex: location.sheetIndex, slide: location.slide, frame: location.frame,
                                         message: hasVisualSection ? nil : location.message, note: hasVisualSection ? nil : location.note, chapter: location.chapter)
        guard section != ConversionLocation(),
              !mappings.isEmpty else { return nil }
        let candidates = mappings.filter { includes(normalized($0.source), requested: section) }
        guard sections(candidates, limit: 2).count <= 1, let first = candidates.first else { return nil }
        return ComparisonTarget(range: first.output, exact: false)
    }

    private static func sameDetail(_ source: ConversionLocation, requested: ConversionLocation) -> Bool {
        let aligned = ConversionLocation(page: source.page, sheet: source.sheet, cell: source.cell,
            sheetIndex: requested.sheetIndex == nil ? nil : source.sheetIndex, slide: source.slide, frame: source.frame,
            paragraph: source.paragraph, message: source.message, note: source.note, chapter: source.chapter)
        return aligned == requested
    }

    private static func normalized(_ location: ConversionLocation) -> ConversionLocation {
        // Ältere Präsentationsdiagnosen tragen die Foliennummer zusätzlich
        // im Seitenfeld. Dieser Alias darf einen belegten Folienbezug nicht sperren.
        let alias = location.page != nil && (location.page == location.slide || location.page == location.frame)
        return ConversionLocation(page: alias ? nil : location.page, sheet: location.sheet, cell: location.cell, sheetIndex: location.sheetIndex,
            slide: location.slide, frame: location.frame, paragraph: location.paragraph, message: location.message, note: location.note, chapter: location.chapter)
    }

    private static func includes(_ source: ConversionLocation, requested: ConversionLocation) -> Bool {
        (requested.page == nil || source.page == requested.page)
            && (requested.sheet == nil || source.sheet == requested.sheet)
            && (requested.sheetIndex == nil || source.sheetIndex == requested.sheetIndex)
            && (requested.cell == nil || source.cell == requested.cell)
            && (requested.slide == nil || source.slide == requested.slide)
            && (requested.frame == nil || source.frame == requested.frame)
            && (requested.paragraph == nil || source.paragraph == requested.paragraph)
            && (requested.message == nil || source.message == requested.message)
            && (requested.note == nil || source.note == requested.note)
            && (requested.chapter == nil || source.chapter == requested.chapter)
    }
}
