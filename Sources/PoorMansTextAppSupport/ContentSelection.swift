import AppKit
import Foundation
import PoorMansTextCore

public enum ContentOverview: Sendable {
    case pdf(PDFContentSummary)
    case spreadsheet(SpreadsheetContentSummary)
    case presentation(PresentationContentSummary)
    case epub(EPUBContentSummary)
    case complete(InputFormat)

    public var identity: ConversionSourceIdentity? {
        switch self {
        case .pdf(let value): value.sourceIdentity
        case .spreadsheet(let value): value.sourceIdentity
        case .presentation(let value): value.sourceIdentity
        case .epub(let value): value.sourceIdentity
        case .complete: nil
        }
    }
    public static func read(_ input: URL, cancellation: ConversionCancellationToken) throws -> Self {
        let converter = DocumentConverter()
        let format = try converter.detectFormat(at: input, cancellation: cancellation, processTimeout: 120)
        switch format {
        case .pdf: return .pdf(try converter.inspectPDFContents(input, cancellation: cancellation, processTimeout: 120))
        case .xlsx, .xls, .ods: return .spreadsheet(try converter.inspectSpreadsheetContents(input, cancellation: cancellation, processTimeout: 120))
        case .pptx, .odp: return .presentation(try converter.inspectPresentationContents(input, cancellation: cancellation, processTimeout: 120))
        case .epub: return .epub(try converter.inspectEPUBContents(input, cancellation: cancellation, processTimeout: 120))
        default: return .complete(format)
        }
    }
}

public enum DocumentContentSelection: Equatable, Sendable {
    case pdf(IndexSelection)
    case spreadsheet(SpreadsheetSelection)
    case presentation(PresentationSelection)
    case epub(IndexSelection)

    public func applying(to options: ConversionOptions) -> ConversionOptions {
        var options = options
        options.pdfPages = nil; options.spreadsheetSelection = nil
        options.presentationSelection = nil; options.epubChapters = nil
        switch self {
        case .pdf(let value): options.pdfPages = value
        case .spreadsheet(let value): options.spreadsheetSelection = value
        case .presentation(let value): options.presentationSelection = value
        case .epub(let value): options.epubChapters = value
        }
        return options
    }
}

/// Fensterlokal; ein spätes Ergebnis darf eine neue Auswahl nicht ersetzen.
@MainActor
public final class ContentSelectionModel: ObservableObject {
    @Published public private(set) var overview: ContentOverview?
    @Published public private(set) var error: String?
    @Published public private(set) var isLoading = false
    public let input: URL
    private var task: Task<Void, Never>?
    private var cancellation: ConversionCancellationToken?
    private var generation = UUID()

    public init(input: URL) { self.input = input }
    public func load() {
        cancel()
        let token = ConversionCancellationToken(), current = UUID(), input = input
        cancellation = token; generation = current
        overview = nil; error = nil; isLoading = true
        task = Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try ContentOverview.read(input, cancellation: token)
                }.value
                guard generation == current, !token.isCancelled else { return }
                overview = value; isLoading = false; task = nil; cancellation = nil
            } catch {
                guard generation == current, !token.isCancelled else { return }
                self.error = AppErrorMessage.describe(error); isLoading = false; task = nil; cancellation = nil
            }
        }
    }
    public func cancel() {
        generation = UUID(); cancellation?.cancel(); cancellation = nil
        task?.cancel(); task = nil; isLoading = false; overview = nil; error = nil
    }
}

public struct ContentSelectionFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = NSLocalizedString(message, comment: "") }
    public var errorDescription: String? { message }
}

/// Gemeinsame Syntax für Oberflächen; keine implizite Format- oder Blattauswahl.
public enum ContentSelectionParsing {
    public static func indices(_ text: String) throws -> IndexSelection? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : try IndexSelection(value)
    }
    public static func ranges(_ text: String) throws -> [SpreadsheetCellRange] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count <= 64 else { throw ContentSelectionFailure("Select at most 64 cell ranges.") }
        return try fields.map { try SpreadsheetCellRange($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    public static func requiredIndices(_ text: String, count: Int) throws -> IndexSelection {
        guard let value = try indices(text) else { throw ContentSelectionFailure("Select at least one item.") }
        _ = try value.zeroBasedIndices(itemCount: count)
        return value
    }
}
