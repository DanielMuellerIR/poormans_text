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

public struct ConvertDocumentIntent: AppIntent {
    public static let title: LocalizedStringResource = "Convert Document to Markdown"
    public static let description = IntentDescription("Convert one document into a new folder or Textbundle, including its images. Existing results are never overwritten. The result is the file URL of the complete output folder; conversion warnings are returned in the dialog.")
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
            \.$toolTimeout
        }
    }

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        guard toolTimeout.isFinite, toolTimeout > 0 else {
            throw ShortcutFailure(message: String(localized: "The tool timeout must be a positive number."))
        }
        let options = ConversionOptions(
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
        let document = document
        let destination = destinationFolder
        let timeout = toolTimeout
        let cancellation = ConversionCancellationToken()
        let result: ConversionResult
        do {
            result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ShortcutConversion.convert(document, into: destination, options: options, timeout: timeout, cancellation: cancellation)
                }.value
            } onCancel: { cancellation.cancel() }
        } catch {
            throw ShortcutFailure(message: AppErrorMessage.describe(error))
        }
        let message = result.warnings.isEmpty
            ? String(localized: "The document was converted.")
            : String(localized: "The document was converted with warnings:") + "\n" + result.warnings.joined(separator: "\n")
        return .result(value: result.outputDirectory, dialog: IntentDialog(stringLiteral: message))
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
