import Foundation

/// Maschinenlesbare Warnung mit stabilem Code und verständlicher Meldung.
public struct ConversionWarning: Codable, Hashable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

extension ConversionWarning {
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

    static let legacySpreadsheetPotentialLoss = ConversionWarning(
        code: "legacySpreadsheet.potentialLoss",
        message: "Legacy XLS import preserves stored cell values but can omit formatting and unsupported workbook features."
    )

    static let openDocumentMasterFlattened = ConversionWarning(
        code: "openDocumentMaster.flattened",
        message: "Master-document sections were flattened; master styles, indexes, and cross-document page layout are not represented."
    )
}
