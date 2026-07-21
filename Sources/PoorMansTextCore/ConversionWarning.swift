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
}
