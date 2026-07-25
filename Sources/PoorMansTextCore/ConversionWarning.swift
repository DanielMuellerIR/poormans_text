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

    static let openDocumentChangesNotPreserved = ConversionWarning(
        code: "openDocument.changesNotPreserved",
        message: "Tracked changes in ODT are not represented reliably in the generated Markdown."
    )

    static let legacyWordPotentialLoss = ConversionWarning(
        code: "legacyWord.potentialLoss",
        message: "Legacy DOC import can omit OLE objects, text boxes, macros, and other unsupported Word content."
    )
}
