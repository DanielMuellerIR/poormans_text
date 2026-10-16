import Foundation

/// Bedeutung einer Diagnose; keine Fehlerstufe und kein Qualitätsversprechen.
public enum ConversionDiagnosticKind: String, Codable, Hashable, Sendable {
    case information
    case approximation
    case contentLoss
}

/// Maschinenlesbare Diagnose. Der bisherige Typname bleibt quellkompatibel.
public struct ConversionWarning: Codable, Hashable, Sendable {
    public let code: String
    public let message: String
    public let location: ConversionLocation?
    public let kind: ConversionDiagnosticKind
    public let omittedCount: Int?

    public init(code: String, message: String, location: ConversionLocation? = nil,
                kind: ConversionDiagnosticKind? = nil, omittedCount: Int? = nil) {
        self.code = code
        self.message = message
        self.location = location
        self.kind = kind ?? Self.defaultKind(for: code)
        self.omittedCount = omittedCount.map { max(0, $0) }
    }

    private enum CodingKeys: String, CodingKey { case code, message, location, kind, omittedCount }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let code = try values.decode(String.self, forKey: .code)
        self.init(code: code, message: try values.decode(String.self, forKey: .message),
                  location: try values.decodeIfPresent(ConversionLocation.self, forKey: .location),
                  kind: try values.decodeIfPresent(String.self, forKey: .kind).flatMap(ConversionDiagnosticKind.init(rawValue:)),
                  omittedCount: try values.decodeIfPresent(Int.self, forKey: .omittedCount))
    }

    private static func defaultKind(for code: String) -> ConversionDiagnosticKind {
        switch code {
        case "metadata.unavailable", "wordProcessing.changesAccepted", "pdf.ocrApplied", "image.ocrApplied",
             "image.textUnavailable", "pdf.repeatedMarginRemoved", "mail.partSavedAsAttachment",
             "html.remoteImagesKeptAsLinks", "notebook.rawCellPreservedAsText", "notebook.externalReferenceNotLoaded",
             "notebook.htmlNotInterpreted", "diagnostics.limited", "diagnostics.locationsLimited":
            return .information
        case "richText.attachmentNotRepresented", "wordProcessing.commentsNotPreserved", "wordProcessing.macrosNotPreserved",
             "wordProcessing.templateSemanticsNotPreserved", "openDocument.changesNotPreserved",
             "spreadsheet.formulaResultMissing", "spreadsheet.unsupportedObjects", "spreadsheet.macrosNotPreserved",
             "spreadsheet.templateSemanticsNotPreserved", "spreadsheet.hyperlinkNotPreserved", "html.missingImagesDropped",
             "presentation.hyperlinkFlattened", "presentation.imageUnavailable", "presentation.macrosNotPreserved",
             "presentation.notesUnavailable", "presentation.objectNotRepresented", "notebook.attachmentUnavailable",
             "notebook.imageUnavailable", "notebook.resourceUnavailable", "notebook.outputNotRepresented":
            return .contentLoss
        default:
            return .approximation
        }
    }
}

extension ConversionWarning {
    static let metadataUnavailable = ConversionWarning(
        code: "metadata.unavailable",
        message: "The source carries no title, author, or dates, so no frontmatter was written."
    )

    static let richTextColorNotPreserved = ConversionWarning(
        code: "richText.colorNotPreserved",
        message: "Chromatic text colors in RTF cannot be represented and were not preserved."
    )

    static func richTextAttachmentNotRepresented(_ name: String) -> ConversionWarning {
        ConversionWarning(
            code: "richText.attachmentNotRepresented",
            message: "Attachment was not represented in the generated Markdown: \(name)"
        )
    }

    static let wordProcessingCommentsNotPreserved = ConversionWarning(
        code: "wordProcessing.commentsNotPreserved",
        message: "Document comments are not represented in the generated Markdown."
    )

    static let wordProcessingChangesAccepted = ConversionWarning(
        code: "wordProcessing.changesAccepted",
        message: "Tracked changes were accepted before the Markdown was generated."
    )

    static let wordProcessingMacrosNotPreserved = ConversionWarning(
        code: "wordProcessing.macrosNotPreserved",
        message: "Word macros cannot be represented in Markdown and were not preserved."
    )

    static let wordProcessingTemplateSemanticsNotPreserved = ConversionWarning(
        code: "wordProcessing.templateSemanticsNotPreserved",
        message: "The Word template function cannot be represented in Markdown and was not preserved."
    )

    static let openDocumentChangesNotPreserved = ConversionWarning(
        code: "openDocument.changesNotPreserved",
        message: "Tracked changes in ODT are not represented reliably in the generated Markdown."
    )

    static let legacyWordPotentialLoss = ConversionWarning(
        code: "legacyWord.potentialLoss",
        message: "Legacy DOC import can omit OLE objects, text boxes, macros, and other unsupported Word content."
    )

    static let spreadsheetMergesFlattened = ConversionWarning(
        code: "spreadsheet.mergesFlattened",
        message: "Merged cells were reduced to the value in their upper-left cell."
    )

    static let spreadsheetFormulaResultMissing = ConversionWarning(
        code: "spreadsheet.formulaResultMissing",
        message: "At least one formula has no stored result; its cell is empty in the Markdown."
    )

    static let spreadsheetUnsupportedObjects = ConversionWarning(
        code: "spreadsheet.unsupportedObjects",
        message: "Charts, images, comments, macros, hyperlink targets, or other spreadsheet objects are not represented in the Markdown."
    )

    static let spreadsheetMacrosNotPreserved = ConversionWarning(
        code: "spreadsheet.macrosNotPreserved",
        message: "Excel macros cannot be represented in Markdown and were not preserved."
    )

    static let spreadsheetTemplateSemanticsNotPreserved = ConversionWarning(
        code: "spreadsheet.templateSemanticsNotPreserved",
        message: "The Excel template function cannot be represented in Markdown and was not preserved."
    )

    static let delimitedTextEncodingAssumed = ConversionWarning(
        code: "delimitedText.encodingAssumed",
        message: "The text is not valid UTF-8 and was read as Windows-1252; check umlauts and special characters."
    )

    static let htmlStructureSimplified = ConversionWarning(
        code: "html.structureSimplified",
        message: "Scripts, styles, forms, and the page layout are not represented in the Markdown."
    )

    static let epubFlattened = ConversionWarning(
        code: "epub.flattened",
        message: "The book was flattened into one Markdown file; chapter files, styles, and navigation are not preserved."
    )

    static let latexSimplified = ConversionWarning(
        code: "latex.simplified",
        message: "Custom LaTeX macros, packages, and layout are not represented; math is kept as LaTeX source."
    )

    static let textEncodingAssumed = ConversionWarning(
        code: "text.encodingAssumed",
        message: "The text is not valid UTF-8 and was read as Windows-1252; check umlauts and special characters."
    )

    static func remoteImagesKeptAsLinks(_ count: Int) -> ConversionWarning {
        ConversionWarning(
            code: "html.remoteImagesKeptAsLinks",
            message: count == 1
                ? "1 remote image was not fetched and is kept as a link."
                : "\(count) remote images were not fetched and are kept as links."
        )
    }

    static func missingImagesDropped(_ count: Int) -> ConversionWarning {
        ConversionWarning(
            code: "html.missingImagesDropped",
            message: count == 1
                ? "1 image could not be found next to the source and was dropped; its alt text remains."
                : "\(count) images could not be found next to the source and were dropped; their alt text remains."
        )
    }

    static let legacySpreadsheetPotentialLoss = ConversionWarning(
        code: "legacySpreadsheet.potentialLoss",
        message: "Legacy XLS import preserves stored cell values but can omit formatting and unsupported workbook features."
    )

    static let openDocumentMasterFlattened = ConversionWarning(
        code: "openDocumentMaster.flattened",
        message: "Master-document sections were flattened; master styles, indexes, and cross-document page layout are not represented."
    )

    static let pdfLayoutNotPreserved = ConversionWarning(
        code: "pdf.layoutNotPreserved",
        message: "Complex PDF layout and exact text placement are not fully preserved. Inferred headings, tables and column order may need review."
    )

    static let pdfOCRApplied = ConversionWarning(
        code: "pdf.ocrApplied",
        message: "Pages without enough embedded text were rendered and read with local OCR. Review OCR text before relying on it."
    )

    static let pdfPageTextUnavailable = ConversionWarning(
        code: "pdf.pageTextUnavailable",
        message: "At least one PDF page contains no extractable text, including local OCR output."
    )

    static let pdfOCRFailed = ConversionWarning(
        code: "pdf.ocrFailed",
        message: "Local OCR failed for at least one PDF page; any embedded fallback text on that page was preserved."
    )

    static let imageOCRApplied = ConversionWarning(
        code: "image.ocrApplied",
        message: "Local OCR text was added next to the preserved original image."
    )

    static let imageOCRDownscaled = ConversionWarning(
        code: "image.ocrDownscaled",
        message: "At least one image frame was scaled down for local OCR; very small text may be missing. The preserved image itself is unchanged."
    )

    static let imageOCRFailed = ConversionWarning(
        code: "image.ocrFailed",
        message: "Local OCR failed for at least one image frame; the original image was preserved."
    )

    static let imageTextUnavailable = ConversionWarning(
        code: "image.textUnavailable",
        message: "No text could be extracted from at least one image frame."
    )
}

/// Optionale, einsbasierte Fundstelle; alte Warnungs-JSONs ohne location bleiben lesbar.
public struct ConversionLocation: Codable, Hashable, Sendable {
    public let page: Int?
    public let sheet: String?
    public let cell: String?
    public let chapter: Int?
    public let sheetIndex: Int?
    public let slide: Int?
    public let frame: Int?
    public let paragraph: Int?
    public let message: String?
    public let note: String?
    public init(page: Int? = nil, sheet: String? = nil, cell: String? = nil, sheetIndex: Int? = nil,
                slide: Int? = nil, frame: Int? = nil, paragraph: Int? = nil,
                message: String? = nil, note: String? = nil, chapter: Int? = nil) {
        self.page = page
        self.sheet = sheet
        self.cell = cell
        self.chapter = chapter
        self.sheetIndex = sheetIndex
        self.slide = slide
        self.frame = frame
        self.paragraph = paragraph
        self.message = message
        self.note = note
    }

    public func merging(_ known: ConversionLocation) -> ConversionLocation {
        ConversionLocation(page: known.page ?? page, sheet: known.sheet ?? sheet, cell: known.cell ?? cell, sheetIndex: known.sheetIndex ?? sheetIndex,
                           slide: known.slide ?? slide, frame: known.frame ?? frame, paragraph: known.paragraph ?? paragraph,
                           message: known.message ?? message, note: known.note ?? note, chapter: known.chapter ?? chapter)
    }

    var label: String {
        [slide.map { "Slide \($0)" } ?? page.map { "Page \($0)" }, sheet.map { "Sheet \($0)" },
         cell.map { "Cell \($0)" }, frame.map { "Frame \($0)" }, paragraph.map { "Paragraph \($0)" },
         message.map { "Message \($0)" }, note.map { "Note \($0)" }, chapter.map { "Chapter \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
}

extension ConversionWarning {
    func at(_ location: ConversionLocation) -> ConversionWarning {
        ConversionWarning(code: code, message: message, location: location, kind: kind, omittedCount: omittedCount)
    }
}
