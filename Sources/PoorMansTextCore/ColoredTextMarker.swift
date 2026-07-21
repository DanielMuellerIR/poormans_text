import AppKit
import Foundation

/// Übersetzt chromatische Vordergrundfarben in die von Fastra verstandene `==`-Notation.
enum ColoredTextMarker {
    static func containsChromaticText(inRTF inputURL: URL) -> Bool {
        guard let document = try? NSAttributedString(
            url: inputURL,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else {
            return false
        }
        let fullRange = NSRange(location: 0, length: document.length)
        for attribute in [NSAttributedString.Key.foregroundColor, .backgroundColor] {
            var found = false
            document.enumerateAttribute(attribute, in: fullRange) { value, _, stop in
                guard let color = value as? NSColor, isChromatic(color) else {
                    return
                }
                found = true
                stop.pointee = true
            }
            if found {
                return true
            }
        }

        // AppKit verwirft einige gültige RTF-Hintergrundsteuerwörter bereits
        // beim Lesen. Der Rohtextcheck dient nur der Verlustwarnung und ändert
        // oder interpretiert den Dokumentinhalt nicht.
        guard let data = try? Data(contentsOf: inputURL),
              let rtf = String(data: data, encoding: .isoLatin1) else {
            return false
        }
        return containsChromaticBackgroundControl(in: rtf)
    }

    static func markedInputURL(from inputURL: URL, outputURL: URL) throws -> URL {
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

    /// Ordnet rohe Hintergrund-Steuerwörter ihrem Eintrag in `\\colortbl`
    /// zu. Dadurch werden Grauwerte nicht fälschlich als chromatisch gemeldet.
    private static func containsChromaticBackgroundControl(in rtf: String) -> Bool {
        guard let tableRange = rtf.range(
            of: #"\{\\colortbl(?:[^{}]|\{[^{}]*\})*\}"#,
            options: .regularExpression
        ) else {
            return false
        }

        let table = String(rtf[tableRange])
        let chromaticIndexes = Set<Int>(
            table.components(separatedBy: ";").enumerated().compactMap { index, entry in
                guard index > 0 else {
                    return nil
                }
                let red = colorComponent("red", in: entry) ?? 0
                let green = colorComponent("green", in: entry) ?? 0
                let blue = colorComponent("blue", in: entry) ?? 0
                return max(red, green, blue) - min(red, green, blue) > 5 ? index : nil
            }
        )
        guard !chromaticIndexes.isEmpty,
              let expression = try? NSRegularExpression(
                pattern: #"\\(?:highlight|chcbpat|cb)([1-9][0-9]*)\b"#
              ) else {
            return false
        }

        let range = NSRange(rtf.startIndex..<rtf.endIndex, in: rtf)
        return expression.matches(in: rtf, range: range).contains { match in
            guard let indexRange = Range(match.range(at: 1), in: rtf),
                  let index = Int(rtf[indexRange]) else {
                return false
            }
            return chromaticIndexes.contains(index)
        }
    }

    private static func colorComponent(_ name: String, in entry: String) -> Int? {
        guard let range = entry.range(
            of: #"\\"# + name + #"([0-9]{1,3})\b"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let component = entry[range].dropFirst(name.count + 1)
        return Int(component)
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
