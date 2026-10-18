import AppIntents
import Foundation
import PoorMansTextCore

// Kurzbefehle initialisiert auch optionale Bool-Schalter mit false. Der eigene
// Zustand verhindert, dass ein unberührter Schalter den Profilwert verdrängt.
public enum ShortcutProfileBooleanChoice: String, AppEnum {
    case fromProfile, enabled, disabled
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Profile option")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .fromProfile: "Profile Value", .enabled: "On", .disabled: "Off"
    ]
    var overrideValue: Bool? {
        switch self {
        case .fromProfile: nil
        case .enabled: true
        case .disabled: false
        }
    }
}

public struct ConvertWithProfileIntent: AppIntent {
    public static let title: LocalizedStringResource = "Convert Document with Profile"
    public static let description = IntentDescription("Convert one document using a saved conversion profile. Profile Value keeps each saved setting; On and Off explicitly override it. The destination folder is required. Existing results are never overwritten. The result is a list: the output folder URL followed by conversion warnings.")
    public static let openAppWhenRun = false

    @Parameter(title: "Document", supportedTypeIdentifiers: ["public.data", "com.apple.package", "com.apple.mail.mbox"]) public var document: IntentFile
    @Parameter(title: "Destination Folder", supportedTypeIdentifiers: ["public.folder"])
    public var destinationFolder: IntentFile
    @Parameter(title: "Textbundle", default: .fromProfile) public var textbundle: ShortcutProfileBooleanChoice
    @Parameter(title: "Include Metadata", default: .fromProfile) public var frontmatter: ShortcutProfileBooleanChoice
    @Parameter(title: "Spreadsheet Format") public var spreadsheetFormat: ShortcutSpreadsheetFormat?
    @Parameter(title: "Recognize Text in Images", default: .fromProfile) public var imageOCR: ShortcutProfileBooleanChoice
    @Parameter(title: "PDF Text Recognition") public var pdfOCR: ShortcutPDFRecognition?
    @Parameter(title: "OCR Method") public var ocrMethod: ShortcutOCRMethod?
    @Parameter(title: "DOCX text changes") public var docxChangeMode: ShortcutDOCXChangeMode?
    @Parameter(title: "OCR Languages") public var ocrLanguages: String?
    @Parameter(title: "PDF Layout") public var pdfLayout: ShortcutPDFLayout?
    @Parameter(title: "Remove Repeated PDF Headers and Footers", default: .fromProfile) public var removeHeadersFooters: ShortcutProfileBooleanChoice
    @Parameter(title: "Join Hyphenated PDF Words", default: .fromProfile) public var dehyphenate: ShortcutProfileBooleanChoice
    @Parameter(title: "PDF Pages (for example 1,3-5)", default: "") public var pdfPages: String
    @Parameter(title: "Sheet Indices (for example 1,3-5)", default: "") public var sheetIndices: String
    @Parameter(title: "Exact Sheet Names", default: []) public var sheetNames: [String]
    @Parameter(title: "Sheet Selection", default: .documentDefault) public var sheetSelection: ShortcutSelectionMode
    @Parameter(title: "Cell Ranges (for example A1:C8,E2)", default: "") public var cellRanges: String
    @Parameter(title: "Slides (for example 1,3-5)", default: "") public var slides: String
    @Parameter(title: "Presentation Notes", default: .documentDefault) public var presentationNotes: ShortcutNotesMode
    @Parameter(title: "EPUB Chapters (for example 1,3-5)", default: "") public var epubChapters: String
    @Parameter(title: "Conversion profile") public var profile: ShortcutProfile
    @Parameter(title: "Allow local profile paths", default: false) public var allowLocalProfile: Bool
    @Parameter(title: "Discard profile document selection", default: false) public var discardProfileSelection: Bool
    @Parameter(title: "Record source locations", default: .fromProfile) public var sourceMapping: ShortcutProfileBooleanChoice
    @Parameter(title: "Write conversion report", default: .fromProfile) public var conversionReport: ShortcutProfileBooleanChoice
    var profileStoreOverride: ConversionProfileStore?

    @Parameter(title: "Tool Timeout in Seconds", default: 120) public var toolTimeout: Double

    public static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$document) into \(\.$destinationFolder) using \(\.$profile)") {
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

    public func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        var adapter = ConvertDocumentIntent()
        adapter.document = document
        adapter.destinationFolder = destinationFolder
        adapter.textbundle = textbundle.overrideValue
        adapter.frontmatter = frontmatter.overrideValue
        adapter.spreadsheetFormat = spreadsheetFormat
        adapter.imageOCR = imageOCR.overrideValue
        adapter.pdfOCR = pdfOCR
        adapter.ocrMethod = ocrMethod
        adapter.docxChangeMode = docxChangeMode
        adapter.ocrLanguages = ocrLanguages
        adapter.pdfLayout = pdfLayout
        adapter.removeHeadersFooters = removeHeadersFooters.overrideValue
        adapter.dehyphenate = dehyphenate.overrideValue
        adapter.pdfPages = pdfPages
        adapter.sheetIndices = sheetIndices
        adapter.sheetNames = sheetNames
        adapter.sheetSelection = sheetSelection
        adapter.cellRanges = cellRanges
        adapter.slides = slides
        adapter.presentationNotes = presentationNotes
        adapter.epubChapters = epubChapters
        adapter.profile = profile
        adapter.allowLocalProfile = allowLocalProfile
        adapter.discardProfileSelection = discardProfileSelection
        adapter.sourceMapping = sourceMapping.overrideValue
        adapter.conversionReport = conversionReport.overrideValue
        adapter.toolTimeout = toolTimeout
        adapter.profileStoreOverride = profileStoreOverride
        return try await adapter.perform()
    }
}
