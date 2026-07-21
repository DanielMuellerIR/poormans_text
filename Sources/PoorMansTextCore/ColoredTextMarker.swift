import AppKit
import Foundation

/// Übersetzt chromatische Vordergrundfarben in die von Fastra verstandene `==`-Notation.
enum ColoredTextMarker {
    static func markedInputURL(from inputURL: URL, outputURL: URL) throws -> URL {
        let document: NSMutableAttributedString
        do {
            document = try NSMutableAttributedString(
                url: inputURL,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            )
        } catch {
            throw ConversionError.invalidRTFD(
                inputURL,
                reason: "rich text could not be read: \(error.localizedDescription)"
            )
        }

        guard insertMarkers(in: document) > 0 else {
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

    /// Fügt Marker rückwärts ein, damit die zuvor ermittelten NSRanges stabil bleiben.
    @discardableResult
    static func insertMarkers(in document: NSMutableAttributedString) -> Int {
        let ranges = chromaticTextRanges(in: document)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            let attributes = neutralMarkerAttributes(in: document, at: range.location)
            let marker = NSAttributedString(string: "==", attributes: attributes)
            document.insert(marker, at: NSMaxRange(range))
            document.insert(marker, at: range.location)
        }
        return ranges.count
    }

    private static func chromaticTextRanges(in document: NSAttributedString) -> [NSRange] {
        guard document.length > 0 else {
            return []
        }

        let fullRange = NSRange(location: 0, length: document.length)
        let text = document.string as NSString
        var ranges = [NSRange]()

        document.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard let color = value as? NSColor, isChromatic(color) else {
                return
            }
            ranges.append(contentsOf: visibleLineRanges(in: text, within: range))
        }
        return ranges
    }

    private static func visibleLineRanges(in text: NSString, within range: NSRange) -> [NSRange] {
        var ranges = [NSRange]()
        var segmentStart = range.location
        let rangeEnd = NSMaxRange(range)

        for location in range.location..<rangeEnd {
            let character = text.character(at: location)
            if character == 0x0A || character == 0x0D || character == 0xFFFC {
                appendTrimmedRange(
                    from: segmentStart,
                    to: location,
                    in: text,
                    result: &ranges
                )
                segmentStart = location + 1
            }
        }
        appendTrimmedRange(from: segmentStart, to: rangeEnd, in: text, result: &ranges)
        return ranges
    }

    private static func appendTrimmedRange(
        from start: Int,
        to end: Int,
        in text: NSString,
        result: inout [NSRange]
    ) {
        var trimmedStart = start
        var trimmedEnd = end

        while trimmedStart < trimmedEnd,
              isWhitespace(text.character(at: trimmedStart)) {
            trimmedStart += 1
        }
        while trimmedEnd > trimmedStart,
              isWhitespace(text.character(at: trimmedEnd - 1)) {
            trimmedEnd -= 1
        }

        guard trimmedEnd > trimmedStart else {
            return
        }
        result.append(NSRange(location: trimmedStart, length: trimmedEnd - trimmedStart))
    }

    private static func isWhitespace(_ codeUnit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(codeUnit) else {
            return false
        }
        return CharacterSet.whitespaces.contains(scalar)
    }

    private static func isChromatic(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0.01 else {
            return false
        }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard let minimum = components.min(), let maximum = components.max() else {
            return false
        }
        return maximum - minimum > 0.02
    }

    private static func neutralMarkerAttributes(
        in document: NSAttributedString,
        at location: Int
    ) -> [NSAttributedString.Key: Any] {
        var attributes = document.attributes(at: location, effectiveRange: nil)
        attributes[.foregroundColor] = NSColor.textColor
        attributes.removeValue(forKey: .backgroundColor)
        attributes.removeValue(forKey: .link)
        attributes.removeValue(forKey: .underlineStyle)
        attributes.removeValue(forKey: .strikethroughStyle)

        if let font = attributes[.font] as? NSFont {
            let manager = NSFontManager.shared
            let withoutBold = manager.convert(font, toNotHaveTrait: .boldFontMask)
            attributes[.font] = manager.convert(withoutBold, toNotHaveTrait: .italicFontMask)
        }
        return attributes
    }
}
