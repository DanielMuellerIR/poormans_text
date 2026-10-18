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

public enum ShortcutOCRMethod: String, AppEnum {
    case standard, structured
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OCR method")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.standard: "Standard OCR", .structured: "Structured OCR (macOS 26+)"]
}

public enum ShortcutDOCXChangeMode: String, AppEnum {
    case accept, reject, mark
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "DOCX text changes")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.accept: "Accept changes", .reject: "Reject changes", .mark: "Mark changes visibly"]
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
    public static let description = IntentDescription("Convert one document into a new folder or Textbundle, including its images. Existing results are never overwritten. The result is a list: the complete output folder's file URL first, followed by any conversion warnings. For reliable profile inheritance in Shortcuts, use Convert Document with Profile.")
    public static let openAppWhenRun = false

    @Parameter(title: "Document") public var document: IntentFile
    @Parameter(title: "Destination Folder", supportedTypeIdentifiers: ["public.folder"])
    public var destinationFolder: IntentFile
    @Parameter(title: "Textbundle") public var textbundle: Bool?
    @Parameter(title: "Include Metadata") public var frontmatter: Bool?
    @Parameter(title: "Spreadsheet Format") public var spreadsheetFormat: ShortcutSpreadsheetFormat?
    @Parameter(title: "Recognize Text in Images") public var imageOCR: Bool?
    @Parameter(title: "PDF Text Recognition") public var pdfOCR: ShortcutPDFRecognition?
    @Parameter(title: "OCR Method") public var ocrMethod: ShortcutOCRMethod?
    @Parameter(title: "DOCX text changes") public var docxChangeMode: ShortcutDOCXChangeMode?
    @Parameter(title: "OCR Languages") public var ocrLanguages: String?
    @Parameter(title: "PDF Layout") public var pdfLayout: ShortcutPDFLayout?
    @Parameter(title: "Remove Repeated PDF Headers and Footers") public var removeHeadersFooters: Bool?
    @Parameter(title: "Join Hyphenated PDF Words") public var dehyphenate: Bool?
    @Parameter(title: "PDF Pages (for example 1,3-5)", default: "") public var pdfPages: String
    @Parameter(title: "Sheet Indices (for example 1,3-5)", default: "") public var sheetIndices: String
    @Parameter(title: "Exact Sheet Names", default: []) public var sheetNames: [String]
    @Parameter(title: "Sheet Selection", default: .documentDefault) public var sheetSelection: ShortcutSelectionMode
    @Parameter(title: "Cell Ranges (for example A1:C8,E2)", default: "") public var cellRanges: String
    @Parameter(title: "Slides (for example 1,3-5)", default: "") public var slides: String
    @Parameter(title: "Presentation Notes", default: .documentDefault) public var presentationNotes: ShortcutNotesMode
    @Parameter(title: "EPUB Chapters (for example 1,3-5)", default: "") public var epubChapters: String
    @Parameter(title: "Conversion profile") public var profile: ShortcutProfile?
    @Parameter(title: "Allow local profile paths", default: false) public var allowLocalProfile: Bool
    @Parameter(title: "Discard profile document selection", default: false) public var discardProfileSelection: Bool
    @Parameter(title: "Record source locations") public var sourceMapping: Bool?
    @Parameter(title: "Write conversion report") public var conversionReport: Bool?
    var profileStoreOverride: ConversionProfileStore?

    @Parameter(title: "Tool Timeout in Seconds", default: 120) public var toolTimeout: Double

    public static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$document) into \(\.$destinationFolder)") {
            \.$profile
            \.$allowLocalProfile
            \.$discardProfileSelection
            \.$sourceMapping
            \.$conversionReport
            \.$textbundle
            \.$frontmatter
            \.$spreadsheetFormat
            \.$imageOCR
            \.$pdfOCR
            \.$ocrMethod
            \.$docxChangeMode
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
        let resolvedOptions = try explicitOptions()
        let profileName = profile?.id
        let store = profileStoreOverride ?? ConversionProfileStore()
        let allowLocal = allowLocalProfile
        let discardSelection = discardProfileSelection
        let explicit = explicitOptionKeys()
        let document = document
        let destination = destinationFolder
        let timeout = toolTimeout
        let cancellation = ConversionCancellationToken()
        let result: ConversionResult
        do {
            result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ShortcutConversion.convert(document, into: destination, options: resolvedOptions, timeout: timeout, cancellation: cancellation, profileName: profileName, store: store, explicit: explicit, allowLocal: allowLocal, discardSelection: discardSelection)
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
        AppShortcut(intent: ConvertWithProfileIntent(), phrases: ["Convert a document using a profile with \(.applicationName)"], shortTitle: "Convert with Profile", systemImageName: "doc.text")
    }
}

private struct ShortcutFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum ShortcutConversion {
    static func convert(_ document: IntentFile, into destination: IntentFile, options explicitOptions: ConversionOptions, timeout: Double, cancellation: ConversionCancellationToken, profileName: String?, store: ConversionProfileStore, explicit: Set<ConversionProfileOptionKey>, allowLocal: Bool, discardSelection: Bool) throws -> ConversionResult {
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
        var options = explicitOptions
        var identity: ConversionSourceIdentity?
        if let profileName {
            let profile = try store.load(named: profileName)
            let resolved = try profile.resolve(for: source, overriding: explicitOptions, explicit: explicit, discardBoundSelection: discardSelection, allowLocalTargets: allowLocal, cancellation: cancellation)
            options = resolved.options; identity = resolved.expectedSourceIdentity
        } else if allowLocal || discardSelection {
            throw AppProfileFailure(key: "Profile modifiers require a selected profile.")
        }
        let name = DocumentConverter.defaultOutputDirectory(for: source, layout: options.outputLayout).lastPathComponent
        return try DocumentConverter().convert(
            ConversionRequest(inputURL: source, destination: .directory(parent.appendingPathComponent(name, isDirectory: true)), options: options, expectedSourceIdentity: identity),
            cancellation: cancellation,
            processTimeout: timeout
        )
    }
}

extension ConvertDocumentIntent {
    func explicitOptions() throws -> ConversionOptions {
        var options = ConversionOptions(
            spreadsheetRendering: spreadsheetFormat == .tsv ? .tabSeparated : .markdownTable,
            imageTextRecognition: imageOCR == false ? .disabled : .enabled,
            frontmatter: frontmatter ?? false,
            outputLayout: textbundle == true ? .textbundle : .markdownFolder,
            pdfTextRecognition: pdfOCR == .always ? .always : pdfOCR == .disabled ? .disabled : .automatic,
            ocrLanguages: (ocrLanguages ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) },
            ocrMethod: ocrMethod == .structured ? .structured : .standard,
            docxChangeMode: docxChangeMode == .mark ? .mark : docxChangeMode == .reject ? .reject : .accept,
            pdfLayout: pdfLayout == .legacy ? .legacy : .automatic,
            pdfRemoveHeadersFooters: removeHeadersFooters ?? false,
            pdfDehyphenate: dehyphenate ?? false,
            presentationIncludeNotes: presentationNotes != .exclude,
            sourceMapping: sourceMapping ?? false, conversionReport: conversionReport ?? false)
        if let selection = try contentSelection() { options = selection.applying(to: options) }
        return options
    }
    func explicitOptionKeys() -> Set<ConversionProfileOptionKey> {
        var keys = Set<ConversionProfileOptionKey>()
        let values: [(Bool, ConversionProfileOptionKey)] = [
            (spreadsheetFormat != nil,.spreadsheetRendering), (imageOCR != nil,.imageTextRecognition),
            (frontmatter != nil,.frontmatter), (textbundle != nil,.outputLayout), (pdfOCR != nil,.pdfTextRecognition),
            (ocrLanguages != nil,.ocrLanguages), (ocrMethod != nil,.ocrMethod), (docxChangeMode != nil,.docxChangeMode),
            (pdfLayout != nil,.pdfLayout), (removeHeadersFooters != nil,.pdfRemoveHeadersFooters), (dehyphenate != nil,.pdfDehyphenate),
            (sourceMapping != nil,.sourceMapping), (conversionReport != nil,.conversionReport),
            (!pdfPages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,.pdfPages),
            (!epubChapters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,.epubChapters),
            (!slides.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,.presentationSlides),
            (presentationNotes != .documentDefault,.presentationIncludeNotes),
            (!sheetIndices.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sheetNames.isEmpty || sheetSelection != .documentDefault,.spreadsheetSheets),
            (!cellRanges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,.spreadsheetRanges)
        ]
        for (present,key) in values where present { keys.insert(key) }
        return keys
    }
}
