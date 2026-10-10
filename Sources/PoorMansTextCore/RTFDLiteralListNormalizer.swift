import AppKit

/// TextEdit-Dokumente können Aufzählungen als gewöhnliche Absätze mit „• “
/// speichern. Ohne Listenmetadaten macht Pandoc daraus getrennte Textabsätze.
enum RTFDLiteralListNormalizer {
    @discardableResult
    static func normalize(_ document: NSMutableAttributedString) -> Int {
        let text = document.string as NSString
        var entries: [(prefix: NSRange, paragraph: NSRange, style: NSParagraphStyle)] = []
        var cursor = 0
        var currentList: NSTextList?
        while cursor < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            cursor = NSMaxRange(paragraph)
            let originalStyle = document.attribute(.paragraphStyle, at: paragraph.location,
                                                   effectiveRange: nil) as? NSParagraphStyle
            guard originalStyle?.textLists.isEmpty != false,
                  let prefix = bulletPrefix(in: text, paragraph: paragraph) else {
                currentList = nil
                continue
            }
            let list = currentList ?? NSTextList(markerFormat: .disc, options: 0)
            currentList = list
            let style = (originalStyle?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.textLists = [list]
            entries.append((prefix, paragraph, style))
        }
        // Rückwärts ändern: Textbereiche und vorhandene Inline-Attribute bleiben
        // bis zum jeweiligen Eingriff gültig. Die Quelldatei wird nie geschrieben.
        for entry in entries.reversed() {
            document.addAttribute(.paragraphStyle, value: entry.style, range: entry.paragraph)
            document.deleteCharacters(in: entry.prefix)
        }
        return entries.count
    }

    private static func bulletPrefix(in text: NSString, paragraph: NSRange) -> NSRange? {
        var cursor = paragraph.location
        let end = NSMaxRange(paragraph)
        while cursor < end, isSpacing(text.character(at: cursor)) { cursor += 1 }
        guard cursor < end, text.character(at: cursor) == 0x2022 else { return nil }
        cursor += 1
        let afterBullet = cursor
        while cursor < end, isSpacing(text.character(at: cursor)) { cursor += 1 }
        guard cursor > afterBullet, cursor < end,
              !CharacterSet.newlines.contains(UnicodeScalar(text.character(at: cursor))
                ?? UnicodeScalar(0)) else { return nil }
        return NSRange(location: paragraph.location, length: cursor - paragraph.location)
    }

    private static func isSpacing(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0xA0
    }
}
