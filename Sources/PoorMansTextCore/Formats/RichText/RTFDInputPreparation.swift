#if os(macOS)
import AppKit

/// Gemeinsame Vorbereitung vor dem HTML-Export durch Cocoa.
enum RTFDInputPreparation {
    /// Bereitet ausschließlich die Arbeitskopie vor: Listenmetadaten zuerst,
    /// dann Farbmarker, damit Listenzeichen nicht innerhalb der Hervorhebung stehen bleiben.
    static func prepare(fromStagedPackage inputURL: URL, outputURL: URL) throws -> URL {
        try normalizeAttachmentGroups(in: inputURL)
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

    private static func normalizeAttachmentGroups(in package: URL) throws {
        let rtf = package.appendingPathComponent("TXT.rtf")
        let source = try Data(contentsOf: rtf, options: .mappedIfSafe)
        guard source.range(of: Data(#"\NeXTGraphic"#.utf8)) != nil else { return }

        let bytes = [UInt8](source)
        func failure(_ reason: String) -> ConversionError { .invalidRichText(package, reason: reason) }
        let attachments: [RTFDAttachmentGroups.Attachment]
        do {
            attachments = try RTFDAttachmentGroups.scan(bytes, rejectInlineObjects: false, failure: failure)
        } catch ConversionError.invalidRichText {
            try ConversionExecution.check()
            return
        }
        for attachment in attachments {
            try ConversionExecution.check()
            // Manche Cocoa-Namen verwenden Unicode-Steuerwörter außerhalb des Byte-Decoders.
            guard
                let names = try? RTFDAttachmentGroups.decodeNames(
                    Array(bytes[attachment.name]), codepage: attachment.codepage, requiresStaticImage: false,
                    failure: failure)
            else { continue }
            let localNames = names.filter(RTFDAttachmentGroups.isLocalFilename)
            guard let name = localNames.first else {
                throw failure("RTFD attachment must name one local package file")
            }
            let exists = localNames.contains { candidate in
                let member = package.appendingPathComponent(candidate)
                return (try? member.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            guard exists else {
                throw failure("RTFD attachment is missing or is not a file: \(name)")
            }
        }
        let bare = attachments.filter { $0.destination == $0.range }
        guard !bare.isEmpty else { return }
        guard source.count <= RichTextLimits.maximumSourceSize - bare.count * 3 else {
            throw ConversionError.invalidRichText(package, reason: "prepared RTFD exceeds its size limit")
        }

        // Ohne die äußere Gruppe mit Bildplatzhalter verschluckt Cocoa den
        // folgenden Text. Nur die Arbeitskopie erhält die Cocoa-Klammerung.
        var normalized = Data(capacity: source.count + bare.count * 3)
        var cursor = 0
        for attachment in bare {
            let range = attachment.destination
            normalized.append(contentsOf: bytes[cursor..<range.lowerBound])
            normalized.append(123)
            normalized.append(contentsOf: bytes[range])
            normalized.append(contentsOf: [0xAC, 125])
            cursor = range.upperBound
        }
        normalized.append(contentsOf: bytes[cursor...])
        try normalized.write(to: rtf, options: .atomic)
    }
}
#endif
