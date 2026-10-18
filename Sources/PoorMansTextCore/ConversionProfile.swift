import Foundation

public struct ConversionProfileError: LocalizedError, Sendable {
    public enum Kind: Sendable { case invalid, collision, missing, localPermission, fileSystem }
    public let kind: Kind
    public let reason: String
    public var errorDescription: String? { reason }
    init(_ reason: String, kind: Kind = .invalid) { self.kind = kind; self.reason = reason }
}

struct ProfileCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
enum ProfileCoding {
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        [.control, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
    }
    static func withCancellation<T>(_ token: ConversionCancellationToken?, _ body: () throws -> T) throws -> T {
        let inherited = ConversionExecution.current
        let context = ConversionExecution.Context(cancellation: token.map { ConversionCancellationToken(parent: $0) } ?? inherited?.cancellation ?? .init(), progress: nil, processTimeout: inherited?.processTimeout)
        return try ConversionExecution.$current.withValue(context) { try ConversionExecution.check(); return try body() }
    }
    static func rejectUnknown(_ decoder: any Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: ProfileCodingKey.self)
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw ConversionProfileError("The profile contains an unknown field.")
        }
    }
    static func path(_ value: String) throws -> URL {
        guard value.hasPrefix("/"), value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: isControl) else {
            throw ConversionProfileError("A local profile path must be an absolute path of at most 4096 bytes.")
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }
}

/// Portable Konvertierungspräferenzen ohne Privatpfade oder Dokumentpositionen.
public struct ConversionProfileOptions: Codable, Equatable, Sendable {
    public var spreadsheetRendering: SpreadsheetRendering
    public var imageTextRecognition: ImageTextRecognition
    public var frontmatter: Bool
    public var outputLayout: OutputLayout
    public var pdfTextRecognition: PDFTextRecognition
    public var ocrLanguages: [String]
    public var ocrMethod: OCRMethod
    public var docxChangeMode: DOCXChangeMode
    public var pdfLayout: PDFLayout
    public var pdfRemoveHeadersFooters: Bool
    public var pdfDehyphenate: Bool
    public var presentationIncludeNotes: Bool
    public var sourceMapping: Bool
    public var conversionReport: Bool
    public init(_ options: ConversionOptions = .init()) {
        spreadsheetRendering = options.spreadsheetRendering
        imageTextRecognition = options.imageTextRecognition
        frontmatter = options.frontmatter
        outputLayout = options.outputLayout
        pdfTextRecognition = options.pdfTextRecognition
        ocrLanguages = options.ocrLanguages
        ocrMethod = options.ocrMethod
        docxChangeMode = options.docxChangeMode
        pdfLayout = options.pdfLayout
        pdfRemoveHeadersFooters = options.pdfRemoveHeadersFooters
        pdfDehyphenate = options.pdfDehyphenate
        presentationIncludeNotes = options.presentationSelection?.includeNotes ?? options.presentationIncludeNotes
        sourceMapping = options.sourceMapping
        conversionReport = options.conversionReport
    }
    public var conversionOptions: ConversionOptions {
        .init(
            spreadsheetRendering: spreadsheetRendering,
            imageTextRecognition: imageTextRecognition,
            frontmatter: frontmatter,
            outputLayout: outputLayout,
            pdfTextRecognition: pdfTextRecognition,
            ocrLanguages: ocrLanguages,
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
    enum CodingKeys: String, CodingKey, CaseIterable {
        case spreadsheetRendering, imageTextRecognition, frontmatter, outputLayout, pdfTextRecognition, ocrLanguages, ocrMethod, docxChangeMode, pdfLayout, pdfRemoveHeadersFooters, pdfDehyphenate, presentationIncludeNotes, sourceMapping, conversionReport
    }
    public init(from decoder: any Decoder) throws {
        try ProfileCoding.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spreadsheetRendering = c.contains(.spreadsheetRendering) ? try c.decode(SpreadsheetRendering.self, forKey: .spreadsheetRendering) : .markdownTable
        imageTextRecognition = c.contains(.imageTextRecognition) ? try c.decode(ImageTextRecognition.self, forKey: .imageTextRecognition) : .enabled
        frontmatter = c.contains(.frontmatter) ? try c.decode(Bool.self, forKey: .frontmatter) : false
        outputLayout = c.contains(.outputLayout) ? try c.decode(OutputLayout.self, forKey: .outputLayout) : .markdownFolder
        pdfTextRecognition = c.contains(.pdfTextRecognition) ? try c.decode(PDFTextRecognition.self, forKey: .pdfTextRecognition) : .automatic
        ocrLanguages = c.contains(.ocrLanguages) ? try c.decode([String].self, forKey: .ocrLanguages) : []
        ocrMethod = c.contains(.ocrMethod) ? try c.decode(OCRMethod.self, forKey: .ocrMethod) : .standard
        docxChangeMode = c.contains(.docxChangeMode) ? try c.decode(DOCXChangeMode.self, forKey: .docxChangeMode) : .accept
        pdfLayout = c.contains(.pdfLayout) ? try c.decode(PDFLayout.self, forKey: .pdfLayout) : .automatic
        pdfRemoveHeadersFooters = c.contains(.pdfRemoveHeadersFooters) ? try c.decode(Bool.self, forKey: .pdfRemoveHeadersFooters) : false
        pdfDehyphenate = c.contains(.pdfDehyphenate) ? try c.decode(Bool.self, forKey: .pdfDehyphenate) : false
        presentationIncludeNotes = c.contains(.presentationIncludeNotes) ? try c.decode(Bool.self, forKey: .presentationIncludeNotes) : true
        sourceMapping = c.contains(.sourceMapping) ? try c.decode(Bool.self, forKey: .sourceMapping) : false
        conversionReport = c.contains(.conversionReport) ? try c.decode(Bool.self, forKey: .conversionReport) : false
        try validate()
    }
    public func validate() throws {
        guard ocrLanguages.count <= 32, ocrLanguages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw ConversionProfileError("Profile OCR languages exceed their limit.")
        }
        do { _ = try OCRLanguageSelection.resolve(ocrLanguages) }
        catch { throw ConversionProfileError("The profile contains unsupported OCR languages.") }
    }
}

public struct ConversionProfileSpreadsheetSelection: Codable, Equatable, Sendable {
    public var sheets: String?
    public var sheetNames: [String]?
    public var cellRanges: [SpreadsheetCellRange]
    init(_ selection: SpreadsheetSelection) {
        switch selection.sheets {
        case .all: sheets = "all"
        case .visible: sheets = "visible"
        case .indices(let indices): sheets = indices.description
        case .names(let names): sheetNames = names
        }
        cellRanges = selection.ranges
    }
    public var selection: SpreadsheetSelection {
        get throws {
            guard sheets == nil || sheetNames == nil else { throw ConversionProfileError("A profile cannot combine sheet indices and sheet names.") }
            let scope: SpreadsheetSheetSelection
            if let names = sheetNames { scope = .names(names) }
            else if sheets == "visible" { scope = .visible }
            else if let sheets, sheets != "all" { scope = .indices(try IndexSelection(sheets)) }
            else { scope = .all }
            return try SpreadsheetSelection(sheets: scope, ranges: cellRanges)
        }
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case sheets, sheetNames, cellRanges }
    public init(from decoder: any Decoder) throws {
        try ProfileCoding.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sheets = try c.decodeIfPresent(String.self, forKey: .sheets)
        sheetNames = try c.decodeIfPresent([String].self, forKey: .sheetNames)
        cellRanges = c.contains(.cellRanges) ? try c.decode([SpreadsheetCellRange].self, forKey: .cellRanges) : []
        _ = try selection
    }
}

public struct ConversionProfileSelection: Codable, Equatable, Sendable {
    public var pdfPages: IndexSelection?
    public var epubChapters: IndexSelection?
    public var presentationSlides: IndexSelection?
    public var spreadsheet: ConversionProfileSpreadsheetSelection?
    init(_ options: ConversionOptions) {
        pdfPages = options.pdfPages; epubChapters = options.epubChapters
        presentationSlides = options.presentationSelection?.slides
        spreadsheet = options.spreadsheetSelection.map(ConversionProfileSpreadsheetSelection.init)
    }
    var count: Int { [pdfPages != nil, epubChapters != nil, presentationSlides != nil, spreadsheet != nil].filter { $0 }.count }
    func validate() throws {
        guard count == 1 else { throw ConversionProfileError("A document-bound profile must contain exactly one format's content selection.") }
        _ = try spreadsheet?.selection
    }
    func apply(to options: inout ConversionOptions) throws {
        try validate()
        options.pdfPages = pdfPages; options.epubChapters = epubChapters
        options.presentationSelection = presentationSlides.map { PresentationSelection(slides: $0, includeNotes: options.presentationIncludeNotes) }
        options.spreadsheetSelection = try spreadsheet?.selection
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case pdfPages, epubChapters, presentationSlides, spreadsheet }
    public init(from decoder: any Decoder) throws {
        try ProfileCoding.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pdfPages = try c.decodeIfPresent(IndexSelection.self, forKey: .pdfPages)
        epubChapters = try c.decodeIfPresent(IndexSelection.self, forKey: .epubChapters)
        presentationSlides = try c.decodeIfPresent(IndexSelection.self, forKey: .presentationSlides)
        spreadsheet = try c.decodeIfPresent(ConversionProfileSpreadsheetSelection.self, forKey: .spreadsheet)
        try validate()
    }
}

public struct ConversionProfileDocumentBinding: Codable, Equatable, Sendable {
    public let sha256: String
    public let byteCount: Int
    public let selection: ConversionProfileSelection
    init(source: URL, selection: ConversionProfileSelection) throws {
        try selection.validate()
        let converter = DocumentConverter(), format = try converter.detectFormat(at: source)
        let matches = (selection.pdfPages != nil && format == .pdf)
            || (selection.epubChapters != nil && format == .epub)
            || (selection.presentationSlides != nil && [.pptx, .odp].contains(format))
            || (selection.spreadsheet != nil && [.xlsx, .xls, .ods].contains(format))
        guard matches else { throw ConversionProfileError("The profile selection does not match its bound document format.") }
        func check(_ indices: IndexSelection, count: Int) throws {
            do { _ = try indices.zeroBasedIndices(itemCount: count) }
            catch { throw ConversionProfileError("The profile content selection exceeds its bound document.") }
        }
        let identity: ConversionSourceIdentity
        if let pages = selection.pdfPages {
            let summary = try converter.inspectPDFContents(source, maximumPages: 1)
            try check(pages, count: summary.pageCount); identity = summary.sourceIdentity
        } else if let chapters = selection.epubChapters {
            let summary = try converter.inspectEPUBContents(source, maximumChapters: 1)
            try check(chapters, count: summary.chapterCount); identity = summary.sourceIdentity
        } else if let slides = selection.presentationSlides {
            let summary = try converter.inspectPresentationContents(source, maximumSlides: 1)
            try check(slides, count: summary.slideCount); identity = summary.sourceIdentity
        } else {
            let summary = try converter.inspectSpreadsheetContents(source)
            if let scope = try selection.spreadsheet?.selection.sheets {
                switch scope {
                case .indices(let indices): try check(indices, count: summary.sheets.count)
                case .names(let names):
                    guard names.allSatisfy({ name in summary.sheets.filter { $0.name == name }.count == 1 }) else {
                        throw ConversionProfileError("The profile contains a missing or ambiguous sheet name in its bound document.")
                    }
                case .visible:
                    guard summary.sheets.contains(where: { $0.visibility == .visible }) else { throw ConversionProfileError("The bound document has no visible sheet.") }
                case .all: break
                }
            }
            identity = summary.sourceIdentity
        }
        guard let hash = identity.sha256, let count = identity.byteCount else { throw ConversionProfileError("The bound document could not be fingerprinted.") }
        sha256 = hash; byteCount = count; self.selection = selection
    }
    func validate() throws {
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (0...1_073_741_824).contains(byteCount) else { throw ConversionProfileError("The profile document binding has an invalid fingerprint.") }
        try selection.validate()
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case sha256, byteCount, selection }
    public init(from decoder: any Decoder) throws {
        try ProfileCoding.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = try c.decode(String.self, forKey: .sha256)
        byteCount = try c.decode(Int.self, forKey: .byteCount)
        selection = try c.decode(ConversionProfileSelection.self, forKey: .selection)
        try validate()
    }
    public func identity(for source: URL, cancellation: ConversionCancellationToken? = nil) throws -> ConversionSourceIdentity {
        try validate()
        let identity = ConversionSourceIdentity(name: source.lastPathComponent, sha256: sha256, byteCount: byteCount, unavailableReason: nil)
        guard try ProfileCoding.withCancellation(cancellation, { try identity.matchesFile(at: source) }) else { throw ConversionProfileError("The profile content selection belongs to different document bytes. Clear it explicitly or choose the bound document.") }
        return identity
    }
}

public struct ConversionProfileLocalTargets: Codable, Equatable, Sendable {
    public let outputDirectory: URL?
    public let pandocExecutable: URL?
    public init(outputDirectory: URL? = nil, pandocExecutable: URL? = nil) throws {
        for url in [outputDirectory, pandocExecutable].compactMap({ $0 }) {
            guard url.isFileURL, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.host == nil || url.host == "" || url.host == "localhost" else { throw ConversionProfileError("Profile local targets must be file paths.") }
            _ = try ProfileCoding.path(url.path)
        }
        guard outputDirectory != nil || pandocExecutable != nil else { throw ConversionProfileError("Empty local profile targets are not valid.") }
        self.outputDirectory = outputDirectory; self.pandocExecutable = pandocExecutable
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case outputDirectory, pandocExecutable }
    public init(from decoder: any Decoder) throws {
        try ProfileCoding.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(outputDirectory: c.decodeIfPresent(String.self, forKey: .outputDirectory).map(ProfileCoding.path),
                      pandocExecutable: c.decodeIfPresent(String.self, forKey: .pandocExecutable).map(ProfileCoding.path))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(outputDirectory?.path, forKey: .outputDirectory)
        try c.encodeIfPresent(pandocExecutable?.path, forKey: .pandocExecutable)
    }
}

public enum ConversionProfileOptionKey: String, CaseIterable, Sendable {
    case spreadsheetRendering, imageTextRecognition, frontmatter, outputLayout, pdfTextRecognition, ocrLanguages, ocrMethod, docxChangeMode, pdfLayout, pdfRemoveHeadersFooters, pdfDehyphenate, presentationIncludeNotes, sourceMapping, conversionReport, pandocExecutable, pdfPages, epubChapters, presentationSlides, spreadsheetSheets, spreadsheetRanges
}
public struct ConversionProfileResolution: Sendable {
    public let options: ConversionOptions
    public let outputDirectory: URL?
    public let expectedSourceIdentity: ConversionSourceIdentity?
}

public struct ConversionProfile: Codable, Equatable, Sendable {
    public static let maximumBytes = 262_144
    public let schemaVersion: Int
    public var name: String
    public var options: ConversionProfileOptions
    public var documentBinding: ConversionProfileDocumentBinding?
    public var localTargets: ConversionProfileLocalTargets?
    public var scope: String {
        localTargets != nil ? (documentBinding != nil ? "localDocumentBound" : "local") : (documentBinding != nil ? "documentBound" : "portable")
    }
    public init(name: String, options: ConversionOptions = .init(), boundSource: URL? = nil, outputDirectory: URL? = nil, allowLocalTargets: Bool = false, cancellation: ConversionCancellationToken? = nil) throws {
        schemaVersion = 1; self.name = name.precomposedStringWithCanonicalMapping
        self.options = ConversionProfileOptions(options)
        let selection = ConversionProfileSelection(options)
        if selection.count != 0 {
            guard let boundSource else { throw ConversionProfileError("Saving content selections requires an explicitly bound source document.") }
            documentBinding = try ProfileCoding.withCancellation(cancellation) { try ConversionProfileDocumentBinding(source: boundSource, selection: selection) }
        } else if boundSource != nil { throw ConversionProfileError("Binding a profile requires a content selection.") }
        if outputDirectory != nil || options.pandocExecutable != nil {
            guard allowLocalTargets else { throw ConversionProfileError("Saving local targets requires explicit local-profile permission.", kind: .localPermission) }
            localTargets = try .init(outputDirectory: outputDirectory, pandocExecutable: options.pandocExecutable)
        }
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw ConversionProfileError("The profile schema version is not supported.") }
        guard !name.isEmpty, name.utf8.count <= 128, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              ![".", ".."].contains(name), !name.contains(where: { "/\\:".contains($0) }),
              !name.unicodeScalars.contains(where: ProfileCoding.isControl) else {
            throw ConversionProfileError("A profile name must contain 1 through 128 UTF-8 bytes, without path separators, control characters or surrounding whitespace.")
        }
        try options.validate(); try documentBinding?.validate()
    }
    public func requireLocalPermission(_ allowed: Bool) throws {
        guard localTargets == nil || allowed else { throw ConversionProfileError("This profile contains local targets. Explicit local-profile permission is required.", kind: .localPermission) }
    }
    public func resolve(for source: URL? = nil, overriding overrides: ConversionOptions = .init(), explicit: Set<ConversionProfileOptionKey> = [], discardBoundSelection: Bool = false, allowLocalTargets: Bool = false, cancellation: ConversionCancellationToken? = nil) throws -> ConversionProfileResolution {
        try validate(); try requireLocalPermission(allowLocalTargets)
        var resolved = options.conversionOptions
        resolved.pandocExecutable = localTargets?.pandocExecutable
        var identity: ConversionSourceIdentity?
        if let binding = documentBinding, !discardBoundSelection {
            guard let source else { throw ConversionProfileError("A document-bound profile requires exactly one source document.") }
            identity = try binding.identity(for: source, cancellation: cancellation)
            try binding.selection.apply(to: &resolved)
        }
        for key in explicit {
            switch key {
            case .spreadsheetRendering: resolved.spreadsheetRendering = overrides.spreadsheetRendering
            case .imageTextRecognition: resolved.imageTextRecognition = overrides.imageTextRecognition
            case .frontmatter: resolved.frontmatter = overrides.frontmatter
            case .outputLayout: resolved.outputLayout = overrides.outputLayout
            case .pdfTextRecognition: resolved.pdfTextRecognition = overrides.pdfTextRecognition
            case .ocrLanguages: resolved.ocrLanguages = overrides.ocrLanguages
            case .ocrMethod: resolved.ocrMethod = overrides.ocrMethod
            case .docxChangeMode: resolved.docxChangeMode = overrides.docxChangeMode
            case .pdfLayout: resolved.pdfLayout = overrides.pdfLayout
            case .pdfRemoveHeadersFooters: resolved.pdfRemoveHeadersFooters = overrides.pdfRemoveHeadersFooters
            case .pdfDehyphenate: resolved.pdfDehyphenate = overrides.pdfDehyphenate
            case .presentationIncludeNotes: resolved.presentationIncludeNotes = overrides.presentationIncludeNotes
            case .sourceMapping: resolved.sourceMapping = overrides.sourceMapping
            case .conversionReport: resolved.conversionReport = overrides.conversionReport
            case .pandocExecutable: resolved.pandocExecutable = overrides.pandocExecutable
            case .pdfPages: resolved.pdfPages = overrides.pdfPages
            case .epubChapters: resolved.epubChapters = overrides.epubChapters
            case .presentationSlides: resolved.presentationSelection = overrides.presentationSelection
            case .spreadsheetSheets:
                resolved.spreadsheetSelection = try .init(sheets: overrides.spreadsheetSelection?.sheets ?? .all, ranges: resolved.spreadsheetSelection?.ranges ?? [])
            case .spreadsheetRanges:
                resolved.spreadsheetSelection = try .init(sheets: resolved.spreadsheetSelection?.sheets ?? .all, ranges: overrides.spreadsheetSelection?.ranges ?? [])
            }
        }
        if let selection = resolved.presentationSelection {
            resolved.presentationSelection = .init(slides: selection.slides, includeNotes: resolved.presentationIncludeNotes)
        }
        try ConversionProfileOptions(resolved).validate()
        return .init(options: resolved, outputDirectory: localTargets?.outputDirectory, expectedSourceIdentity: identity)
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, name, options, documentBinding, localTargets }
    public init(from decoder: any Decoder) throws {
        try ProfileCoding.rejectUnknown(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw ConversionProfileError("The profile schema version is not supported.") }
        name = try c.decode(String.self, forKey: .name).precomposedStringWithCanonicalMapping
        options = try c.decode(ConversionProfileOptions.self, forKey: .options)
        documentBinding = try c.decodeIfPresent(ConversionProfileDocumentBinding.self, forKey: .documentBinding)
        localTargets = try c.decodeIfPresent(ConversionProfileLocalTargets.self, forKey: .localTargets)
        try validate()
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ConversionProfileError("The profile exceeds 256 KiB.") }
        try ProfileJSONPreflight.validate(data)
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch let error as ConversionProfileError { throw error }
        catch { throw ConversionProfileError("The profile JSON contains missing, malformed or invalid values.") }
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ConversionProfileError("The profile exceeds 256 KiB.") }
        return data
    }
}
