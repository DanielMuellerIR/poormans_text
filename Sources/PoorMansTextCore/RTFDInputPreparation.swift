import AppKit

/// Gemeinsame Vorbereitung vor dem HTML-Export durch Cocoa.
enum RTFDInputPreparation {
    /// Bereitet ausschließlich die Arbeitskopie vor: Listenmetadaten zuerst,
    /// dann Farbmarker, damit „• “ nicht innerhalb der Hervorhebung stehen bleibt.
    static func prepare(from inputURL: URL, outputURL: URL) throws -> URL {
        let document: NSMutableAttributedString
        do {
            document = try NSMutableAttributedString(
                url: inputURL,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            )
        } catch {
            throw ConversionError.invalidRichText(
                inputURL,
                reason: "rich text could not be read: \(error.localizedDescription)"
            )
        }

        let listCount = RTFDLiteralListNormalizer.normalize(document)
        let colorCount = ColoredTextMarker.insertMarkers(in: document)
        guard listCount > 0 || colorCount > 0 else {
            return inputURL
        }

        do {
            let wrapper = try document.fileWrapper(
                from: NSRange(location: 0, length: document.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            )
            try wrapper.write(to: outputURL, options: .atomic, originalContentsURL: nil)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        return outputURL
    }

}
