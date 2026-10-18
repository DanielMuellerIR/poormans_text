import Foundation
import PoorMansTextCore

func recordProfileOverride(_ option: String, in parsed: inout ParsedArguments) {
    let keys: [String: ConversionProfileOptionKey] = [
        "--spreadsheet-format": .spreadsheetRendering, "--image-ocr": .imageTextRecognition,
        "--frontmatter": .frontmatter, "--no-frontmatter": .frontmatter,
        "--textbundle": .outputLayout, "--markdown-folder": .outputLayout,
        "--pdf-ocr": .pdfTextRecognition, "--ocr-language": .ocrLanguages, "--ocr-method": .ocrMethod,
        "--docx-changes": .docxChangeMode, "--pdf-layout": .pdfLayout,
        "--pdf-remove-headers-footers": .pdfRemoveHeadersFooters, "--no-pdf-remove-headers-footers": .pdfRemoveHeadersFooters,
        "--pdf-dehyphenate": .pdfDehyphenate, "--no-pdf-dehyphenate": .pdfDehyphenate,
        "--source-map": .sourceMapping, "--no-source-map": .sourceMapping,
        "--report": .conversionReport, "--no-report": .conversionReport,
        "--notes": .presentationIncludeNotes, "--pandoc": .pandocExecutable,
        "--pdf-pages": .pdfPages, "--epub-chapters": .epubChapters, "--slides": .presentationSlides,
        "--sheets": .spreadsheetSheets, "--sheet-name": .spreadsheetSheets, "--cell-range": .spreadsheetRanges,
    ]
    if let key = keys[option] { parsed.profileExplicit.insert(key) }
}

extension ParsedArguments {
    var usesProfiles: Bool {
        profileName != nil || saveProfileName != nil || importProfileURL != nil || exportProfileURL != nil
            || profileDirectory != nil || profileSource != nil || listProfiles || allowLocalProfile || clearProfileSelection
    }
    var conversionOptions: ConversionOptions {
        get throws {
            .init(pandocExecutable: pandocURL, spreadsheetRendering: spreadsheetRendering,
                  imageTextRecognition: imageTextRecognition, frontmatter: frontmatter, outputLayout: outputLayout,
                  pdfTextRecognition: pdfOptions.pdfTextRecognition, ocrLanguages: pdfOptions.ocrLanguages,
                  ocrMethod: pdfOptions.ocrMethod, docxChangeMode: docxChangeMode, pdfLayout: pdfOptions.pdfLayout,
                  pdfRemoveHeadersFooters: pdfOptions.pdfRemoveHeadersFooters, pdfDehyphenate: pdfOptions.pdfDehyphenate,
                  presentationIncludeNotes: presentationIncludeNotes,
                  pdfPages: pdfOptions.pdfPages, epubChapters: epubChapters, presentationSelection: presentationSelection,
                  spreadsheetSelection: setsSpreadsheetSelection ? try SpreadsheetSelection(sheets: sheetSelection, ranges: cellRanges) : nil,
                  sourceMapping: sourceMapping, conversionReport: conversionReport)
        }
    }
    mutating func applyProfileOptions(_ options: ConversionOptions) {
        pandocURL = options.pandocExecutable; spreadsheetRendering = options.spreadsheetRendering
        imageTextRecognition = options.imageTextRecognition; frontmatter = options.frontmatter; outputLayout = options.outputLayout
        pdfOptions = options; docxChangeMode = options.docxChangeMode
        presentationIncludeNotes = options.presentationIncludeNotes; presentationSelection = options.presentationSelection
        if profileExplicit.contains(.presentationIncludeNotes), presentationSelection == nil {
            presentationSelection = .init(includeNotes: presentationIncludeNotes)
        }
        epubChapters = options.epubChapters
        sheetSelection = options.spreadsheetSelection?.sheets ?? .all; cellRanges = options.spreadsheetSelection?.ranges ?? []
        setsSheetSelection = options.spreadsheetSelection != nil
        sourceMapping = options.sourceMapping; conversionReport = options.conversionReport
    }
}

private struct CLIProfileSummary: Encodable {
    let name: String
    let scope: String
    init(_ profile: ConversionProfile) { name = profile.name; scope = profile.scope }
}
private struct CLIProfileResponse: Encodable {
    let ok = true
    let version = ProductInfo.version
    let profiles: [CLIProfileSummary]
    let path: String?
}

/// Verwaltung schreibt ausschließlich Profile; Konvertierung bekommt danach
/// denselben aufgelösten Optionsstand wie die bestehenden CLI-Schalter.
func prepareProfiles(_ arguments: inout ParsedArguments, cancellation: ConversionCancellationToken? = nil) throws -> Bool {
    guard arguments.usesProfiles else { return false }
    guard !arguments.listFormats, !arguments.listSheets, !arguments.listSlides, !arguments.listChapters else {
        throw CLIArgumentError.invalidConversionOption("Profile operations cannot be combined with format or content overviews.")
    }
    let managementCount = [arguments.saveProfileName != nil, arguments.importProfileURL != nil, arguments.exportProfileURL != nil, arguments.listProfiles].filter { $0 }.count
    guard managementCount <= 1 else { throw CLIArgumentError.invalidConversionOption("Choose one profile management operation.") }
    guard arguments.profileSource == nil || arguments.saveProfileName != nil else {
        throw CLIArgumentError.invalidConversionOption("--profile-source is only valid with --save-profile.")
    }
    guard !arguments.clearProfileSelection || arguments.profileName != nil else {
        throw CLIArgumentError.invalidConversionOption("--clear-profile-selection requires --profile.")
    }
    guard managementCount != 0 || arguments.profileName != nil else {
        throw CLIArgumentError.invalidConversionOption("Profile modifiers require a profile selection or management operation.")
    }
    let store = ConversionProfileStore(directory: arguments.profileDirectory ?? ConversionProfileStore.defaultDirectory)
    if managementCount == 1 {
        guard arguments.inputURLs.isEmpty, !arguments.writeToStandardOutput, !arguments.progress, !arguments.setsJobs, arguments.timeout == nil else {
            throw CLIArgumentError.invalidConversionOption("Profile management takes no INPUT, --stdout, --progress, --jobs or --timeout.")
        }
        if arguments.saveProfileName == nil {
            guard arguments.profileExplicit.isEmpty, arguments.outputURL == nil, arguments.profileSource == nil, !arguments.clearProfileSelection else {
                throw CLIArgumentError.invalidConversionOption("Import, export and listing cannot change conversion options.")
            }
        }
        if arguments.listProfiles {
            guard arguments.profileName == nil, !arguments.allowLocalProfile else { throw CLIArgumentError.invalidConversionOption("Profile listing takes only --json and --profiles-directory.") }
            let profiles = try store.profiles().map(CLIProfileSummary.init)
            if arguments.json { writeJSON(CLIProfileResponse(profiles: profiles, path: nil)) }
            else { for profile in profiles { print("\(profile.name)\t\(profile.scope)") } }
            return true
        }
        if let url = arguments.importProfileURL {
            guard arguments.profileName == nil else { throw CLIArgumentError.invalidConversionOption("--import-profile cannot be combined with --profile.") }
            let profile = try ConversionProfileStore.readProfile(at: url)
            try store.save(profile, allowLocalTargets: arguments.allowLocalProfile)
            if arguments.json { writeJSON(CLIProfileResponse(profiles: [.init(profile)], path: nil)) } else { print(profile.name) }
            return true
        }
        if let url = arguments.exportProfileURL {
            guard let name = arguments.profileName else { throw CLIArgumentError.invalidConversionOption("--export-profile requires --profile NAME.") }
            let profile = try store.load(named: name)
            try ConversionProfileStore.export(profile, to: url, allowLocalTargets: arguments.allowLocalProfile)
            if arguments.json { writeJSON(CLIProfileResponse(profiles: [.init(profile)], path: url.path)) } else { print(url.path) }
            return true
        }
    }
    let explicit = try arguments.conversionOptions
    var resolved = explicit, output = arguments.outputURL
    if let name = arguments.profileName {
        let profile = try store.load(named: name)
        let source = arguments.saveProfileName != nil ? arguments.profileSource : arguments.inputURLs.first
        if profile.documentBinding != nil, !arguments.clearProfileSelection, arguments.saveProfileName == nil {
            guard arguments.inputURLs.count == 1, let source, !InputEnumerator().isSearchableDirectory(source) else {
                throw CLIArgumentError.invalidConversionOption("A document-bound profile takes exactly one source file; clear its selection explicitly for batch conversion.")
            }
        }
        let result = try profile.resolve(for: source, overriding: explicit, explicit: arguments.profileExplicit,
                                         discardBoundSelection: arguments.clearProfileSelection, allowLocalTargets: arguments.allowLocalProfile, cancellation: cancellation)
        resolved = result.options; output = output ?? result.outputDirectory
        arguments.expectedSourceIdentity = result.expectedSourceIdentity
    }
    if let name = arguments.saveProfileName {
        let profile = try ConversionProfile(name: name, options: resolved, boundSource: arguments.profileSource,
                                            outputDirectory: output, allowLocalTargets: arguments.allowLocalProfile, cancellation: cancellation)
        try store.save(profile, allowLocalTargets: arguments.allowLocalProfile)
        if arguments.json { writeJSON(CLIProfileResponse(profiles: [.init(profile)], path: nil)) } else { print(profile.name) }
        return true
    }
    arguments.applyProfileOptions(resolved); arguments.outputURL = output
    return false
}
