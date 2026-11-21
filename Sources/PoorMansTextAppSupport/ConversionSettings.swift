import Combine
import Foundation
import PoorMansTextCore

@MainActor
public final class ConversionSettings: ObservableObject {
    public struct Values {
        /// Gilt nur für Bildimporte; andere Formate ignorieren diese Option.
        public var imageTextRecognition: ImageTextRecognition = .enabled
        public var pdfTextRecognition: PDFTextRecognition = .automatic
        public var ocrMethod: OCRMethod = .standard
        public var docxChangeMode: DOCXChangeMode = .accept
        public var pdfLayout: PDFLayout = .automatic
        public var ocrLanguageCodes: String = ""
        public var pdfRemoveHeadersFooters: Bool = false
        public var pdfDehyphenate: Bool = false
        public var spreadsheetRendering: SpreadsheetRendering = .markdownTable
        public var frontmatter = false
        public var outputLayout: OutputLayout = .markdownFolder
        public var presentationIncludeNotes = true
        public var sourceMapping = true
        public var conversionReport = false
        var profilePandocExecutable: URL?
        public var destinationFolder: URL?
        public var batchParallelism = 1 {
            didSet { batchParallelism = min(max(batchParallelism, 1), 4) }
        }

        var conversionOptions: ConversionOptions {
            let languages =
                ocrLanguageCodes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : ocrLanguageCodes.components(separatedBy: ",")
            return ConversionOptions(
                pandocExecutable: profilePandocExecutable,
                spreadsheetRendering: spreadsheetRendering,
                imageTextRecognition: imageTextRecognition,
                frontmatter: frontmatter,
                outputLayout: outputLayout,
                pdfTextRecognition: pdfTextRecognition,
                ocrLanguages: languages,
                ocrMethod: ocrMethod,
                docxChangeMode: docxChangeMode,
                pdfLayout: pdfLayout,
                pdfRemoveHeadersFooters: pdfRemoveHeadersFooters,
                pdfDehyphenate: pdfDehyphenate,
                presentationIncludeNotes: presentationIncludeNotes,
                sourceMapping: sourceMapping,
                conversionReport: conversionReport
            )
        }
    }

    @Published public var values: Values {
        didSet { save() }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        var values = Values()
        values.imageTextRecognition =
            defaults.string(forKey: "imageTextRecognition")
            .flatMap(ImageTextRecognition.init(rawValue:)) ?? values.imageTextRecognition
        values.spreadsheetRendering =
            defaults.string(forKey: "spreadsheetRendering")
            .flatMap(SpreadsheetRendering.init(rawValue:)) ?? values.spreadsheetRendering
        values.frontmatter = defaults.bool(forKey: "frontmatter")
        values.outputLayout =
            defaults.string(forKey: "outputLayout")
            .flatMap(OutputLayout.init(rawValue:)) ?? values.outputLayout
        values.destinationFolder = defaults.string(forKey: "destinationFolder").map {
            URL(fileURLWithPath: $0)
        }
        values.pdfTextRecognition =
            defaults.string(forKey: "pdfTextRecognition")
            .flatMap(PDFTextRecognition.init(rawValue:)) ?? values.pdfTextRecognition
        values.ocrMethod =
            defaults.string(forKey: "ocrMethod")
            .flatMap(OCRMethod.init(rawValue:)) ?? values.ocrMethod
        values.docxChangeMode =
            defaults.string(forKey: "docxChangeMode")
            .flatMap(DOCXChangeMode.init(rawValue:)) ?? values.docxChangeMode
        values.pdfLayout =
            defaults.string(forKey: "pdfLayout")
            .flatMap(PDFLayout.init(rawValue:)) ?? values.pdfLayout
        values.ocrLanguageCodes = defaults.string(forKey: "ocrLanguageCodes") ?? ""
        values.pdfRemoveHeadersFooters = defaults.bool(forKey: "pdfRemoveHeadersFooters")
        values.pdfDehyphenate = defaults.bool(forKey: "pdfDehyphenate")
        values.batchParallelism = defaults.integer(forKey: "batchParallelism")
        if defaults.object(forKey: "presentationIncludeNotes") != nil {
            values.presentationIncludeNotes = defaults.bool(forKey: "presentationIncludeNotes")
        }
        if defaults.object(forKey: "sourceMapping") != nil {
            values.sourceMapping = defaults.bool(forKey: "sourceMapping")
        }
        values.conversionReport = defaults.bool(forKey: "conversionReport")
        values.profilePandocExecutable = defaults.string(forKey: "profilePandocExecutable").map {
            URL(fileURLWithPath: $0)
        }
        self.values = values
    }

    private func save() {
        defaults.set(values.imageTextRecognition.rawValue, forKey: "imageTextRecognition")
        defaults.set(values.spreadsheetRendering.rawValue, forKey: "spreadsheetRendering")
        defaults.set(values.pdfTextRecognition.rawValue, forKey: "pdfTextRecognition")
        defaults.set(values.ocrMethod.rawValue, forKey: "ocrMethod")
        defaults.set(values.docxChangeMode.rawValue, forKey: "docxChangeMode")
        defaults.set(values.pdfLayout.rawValue, forKey: "pdfLayout")
        defaults.set(values.ocrLanguageCodes, forKey: "ocrLanguageCodes")
        defaults.set(values.pdfRemoveHeadersFooters, forKey: "pdfRemoveHeadersFooters")
        defaults.set(values.pdfDehyphenate, forKey: "pdfDehyphenate")
        defaults.set(values.batchParallelism, forKey: "batchParallelism")
        defaults.set(values.frontmatter, forKey: "frontmatter")
        defaults.set(values.outputLayout.rawValue, forKey: "outputLayout")
        defaults.set(values.destinationFolder?.path, forKey: "destinationFolder")
        defaults.set(values.presentationIncludeNotes, forKey: "presentationIncludeNotes")
        defaults.set(values.sourceMapping, forKey: "sourceMapping")
        defaults.set(values.conversionReport, forKey: "conversionReport")
        defaults.set(values.profilePandocExecutable?.path, forKey: "profilePandocExecutable")
    }

    func apply(_ profile: ConversionProfile) {
        let options = profile.options
        var updated = values
        updated.imageTextRecognition = options.imageTextRecognition
        updated.spreadsheetRendering = options.spreadsheetRendering
        updated.frontmatter = options.frontmatter
        updated.outputLayout = options.outputLayout
        updated.pdfTextRecognition = options.pdfTextRecognition
        updated.ocrMethod = options.ocrMethod
        updated.docxChangeMode = options.docxChangeMode
        updated.pdfLayout = options.pdfLayout
        updated.ocrLanguageCodes = options.ocrLanguages.joined(separator: ",")
        updated.pdfRemoveHeadersFooters = options.pdfRemoveHeadersFooters
        updated.pdfDehyphenate = options.pdfDehyphenate
        updated.presentationIncludeNotes = options.presentationIncludeNotes
        updated.sourceMapping = options.sourceMapping
        updated.conversionReport = options.conversionReport
        updated.profilePandocExecutable = profile.localTargets?.pandocExecutable
        if let destination = profile.localTargets?.outputDirectory {
            updated.destinationFolder = destination
        }
        values = updated
    }

    func loadProfileSelection() -> (name: String?, revision: String?, allowsLocalTargets: Bool) {
        (
            defaults.string(forKey: "selectedProfileName"),
            defaults.string(forKey: "selectedProfileRevision"),
            defaults.bool(forKey: "profileAllowsLocalTargets")
        )
    }

    func saveProfileSelection(name: String?, revision: String?, allowsLocalTargets: Bool) {
        defaults.set(name, forKey: "selectedProfileName")
        defaults.set(revision, forKey: "selectedProfileRevision")
        defaults.set(allowsLocalTargets, forKey: "profileAllowsLocalTargets")
    }
}
