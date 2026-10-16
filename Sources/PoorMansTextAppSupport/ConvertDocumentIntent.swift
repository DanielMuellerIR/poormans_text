import AppIntents
import Foundation
import PoorMansTextCore
import UniformTypeIdentifiers

public enum ShortcutSpreadsheetFormat: String, AppEnum {
    case table, tsv
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Spreadsheet format")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.table: "Markdown table", .tsv: "Tab-separated text"]
}

public enum ShortcutPDFRecognition: String, AppEnum {
    case automatic, always, disabled
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "PDF text recognition")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.automatic: "Automatic", .always: "Always", .disabled: "Off"]
}

public enum ShortcutPDFLayout: String, AppEnum {
    case automatic, legacy
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "PDF layout")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.automatic: "Automatic", .legacy: "Legacy"]
}

public enum ShortcutSelectionMode: String, AppEnum {
    case documentDefault, all, visible
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sheet selection")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.documentDefault: "Document Default", .all: "All Sheets", .visible: "Visible Sheets"]
}

public enum ShortcutNotesMode: String, AppEnum {
    case documentDefault, include, exclude
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Presentation notes")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.documentDefault: "Document Default", .include: "Include Notes", .exclude: "Exclude Notes"]
}

public struct ConvertDocumentIntent: AppIntent {
    public static let title: LocalizedStringResource = "Convert Document to Markdown"
    public static let description = IntentDescription("Convert one document into a new folder or Textbundle, including its images. Existing results are never overwritten. The result is a list: the complete output folder's file URL first, followed by any conversion warnings.")
    public static let openAppWhenRun = false

    @Parameter(title: "Document") public var document: IntentFile
    @Parameter(title: "Destination Folder", supportedTypeIdentifiers: ["public.folder"])
    public var destinationFolder: IntentFile
    @Parameter(title: "Textbundle", default: false) public var textbundle: Bool
    @Parameter(title: "Include Metadata", default: false) public var frontmatter: Bool
    @Parameter(title: "Spreadsheet Format", default: .table) public var spreadsheetFormat: ShortcutSpreadsheetFormat
    @Parameter(title: "Recognize Text in Images", default: true) public var imageOCR: Bool
    @Parameter(title: "PDF Text Recognition", default: .automatic) public var pdfOCR: ShortcutPDFRecognition
    @Parameter(title: "OCR Languages", default: "") public var ocrLanguages: String
    @Parameter(title: "PDF Layout", default: .automatic) public var pdfLayout: ShortcutPDFLayout
    @Parameter(title: "Remove Repeated PDF Headers and Footers", default: false) public var removeHeadersFooters: Bool
    @Parameter(title: "Join Hyphenated PDF Words", default: false) public var dehyphenate: Bool
    @Parameter(title: "PDF Pages (for example 1,3-5)", default: "") public var pdfPages: String
    @Parameter(title: "Sheet Indices (for example 1,3-5)", default: "") public var sheetIndices: String
    @Parameter(title: "Exact Sheet Names", default: []) public var sheetNames: [String]
    @Parameter(title: "Sheet Selection", default: .documentDefault) public var sheetSelection: ShortcutSelectionMode
    @Parameter(title: "Cell Ranges (for example A1:C8,E2)", default: "") public var cellRanges: String
    @Parameter(title: "Slides (for example 1,3-5)", default: "") public var slides: String
    @Parameter(title: "Presentation Notes", default: .documentDefault) public var presentationNotes: ShortcutNotesMode
    @Parameter(title: "EPUB Chapters (for example 1,3-5)", default: "") public var epubChapters: String
    @Parameter(title: "Tool Timeout in Seconds", default: 120) public var toolTimeout: Double

    public static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$document) into \(\.$destinationFolder)") {
            \.$textbundle
            \.$frontmatter
            \.$spreadsheetFormat
            \.$imageOCR
            \.$pdfOCR
            \.$ocrLanguages
            \.$pdfLayout
            \.$removeHeadersFooters
            \.$dehyphenate
            \.$pdfPages
            \.$sheetIndices
            \.$sheetNames
            \.$sheetSelection
            \.$cellRanges
            \.$slides
            \.$presentationNotes
            \.$epubChapters
            \.$toolTimeout
        }
    }

    public init() {}

    func contentSelection() throws -> DocumentContentSelection? {
        let pdf = try ContentSelectionParsing.indices(pdfPages)
        let sheets = try ContentSelectionParsing.indices(sheetIndices)
        let ranges = try ContentSelectionParsing.ranges(cellRanges)
        let selectedSlides = try ContentSelectionParsing.indices(slides)
        let chapters = try ContentSelectionParsing.indices(epubChapters)
        let hasSheets = sheets != nil || !sheetNames.isEmpty || sheetSelection != .documentDefault || !ranges.isEmpty
        let hasSlides = selectedSlides != nil || presentationNotes != .documentDefault
        guard [pdf != nil, hasSheets, hasSlides, chapters != nil].filter({ $0 }).count <= 1 else {
            throw ContentSelectionFailure("Select content from only one format family per invocation.")
        }
        if let pdf { return .pdf(pdf) }
        if let chapters { return .epub(chapters) }
        if hasSlides { return .presentation(PresentationSelection(slides: selectedSlides, includeNotes: presentationNotes != .exclude)) }
        if hasSheets {
            guard [sheets != nil, !sheetNames.isEmpty, sheetSelection != .documentDefault].filter({ $0 }).count <= 1 else {
                throw ContentSelectionFailure("Choose sheet indices, exact names, or a visibility mode, not several at once.")
            }
            let chosen: SpreadsheetSheetSelection
            if let sheets { chosen = .indices(sheets) }
            else if !sheetNames.isEmpty { chosen = .names(sheetNames) }
            else { chosen = sheetSelection == .visible ? .visible : .all }
            return .spreadsheet(try SpreadsheetSelection(sheets: chosen, ranges: ranges))
        }
        return nil
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        guard toolTimeout.isFinite, toolTimeout > 0 else {
            throw ShortcutFailure(message: String(localized: "The tool timeout must be a positive number."))
        }
        var options = ConversionOptions(
            spreadsheetRendering: spreadsheetFormat == .table ? .markdownTable : .tabSeparated,
            imageTextRecognition: imageOCR ? .enabled : .disabled,
            frontmatter: frontmatter,
            outputLayout: textbundle ? .textbundle : .markdownFolder,
            pdfTextRecognition: pdfOCR == .automatic ? .automatic : pdfOCR == .always ? .always : .disabled,
            ocrLanguages: ocrLanguages.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) },
            pdfLayout: pdfLayout == .automatic ? .automatic : .legacy,
            pdfRemoveHeadersFooters: removeHeadersFooters,
            pdfDehyphenate: dehyphenate
        )
        if let selection = try contentSelection() { options = selection.applying(to: options) }
        let resolvedOptions = options
        let document = document
        let destination = destinationFolder
        let timeout = toolTimeout
        let cancellation = ConversionCancellationToken()
        let result: ConversionResult
        do {
            result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ShortcutConversion.convert(document, into: destination, options: resolvedOptions, timeout: timeout, cancellation: cancellation)
                }.value
            } onCancel: { cancellation.cancel() }
        } catch {
            throw ShortcutFailure(message: AppErrorMessage.describe(error))
        }
        return .result(value: [result.outputDirectory.absoluteString] + result.warnings)
    }
}

public struct DocumentShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConvertDocumentIntent(), phrases: ["Convert a document with \(.applicationName)"], shortTitle: "Convert Document", systemImageName: "doc.text")
    }
}

private struct ShortcutFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum ShortcutConversion {
    static func convert(_ document: IntentFile, into destination: IntentFile, options: ConversionOptions, timeout: Double, cancellation: ConversionCancellationToken) throws -> ConversionResult {
        try cancellation.checkCancellation()
        guard let parent = destination.fileURL, parent.isFileURL else {
            throw ShortcutFailure(message: String(localized: "Choose a destination folder on this Mac."))
        }
        let destinationAccess = parent.startAccessingSecurityScopedResource()
        defer { if destinationAccess { parent.stopAccessingSecurityScopedResource() } }
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ShortcutFailure(message: String(localized: "Choose a destination folder on this Mac."))
        }
        var temporaryInput: URL?
        defer { if let temporaryInput { try? FileManager.default.removeItem(at: temporaryInput) } }
        let source: URL
        if let fileURL = document.fileURL {
            guard fileURL.isFileURL else { throw ShortcutFailure(message: String(localized: "The document must be a local file.")) }
            source = fileURL
        } else {
            let name = document.filename
            guard !name.isEmpty, name != ".", name != "..", !name.contains("\0"),
                  URL(fileURLWithPath: name).lastPathComponent == name else {
                throw ShortcutFailure(message: String(localized: "The document filename is invalid."))
            }
            let data = document.data
            guard data.count <= 268_435_456 else {
                throw ShortcutFailure(message: String(localized: "The in-memory document exceeds the 256 MiB size limit."))
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PoorMansTextShortcut-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            temporaryInput = root
            source = root.appendingPathComponent(name)
            try data.write(to: source, options: .atomic)
        }
        let sourceAccess = source.startAccessingSecurityScopedResource()
        defer { if sourceAccess { source.stopAccessingSecurityScopedResource() } }
        let name = DocumentConverter.defaultOutputDirectory(for: source, layout: options.outputLayout).lastPathComponent
        return try DocumentConverter().convert(
            ConversionRequest(inputURL: source, destination: .directory(parent.appendingPathComponent(name, isDirectory: true)), options: options),
            cancellation: cancellation,
            processTimeout: timeout
        )
    }
}
