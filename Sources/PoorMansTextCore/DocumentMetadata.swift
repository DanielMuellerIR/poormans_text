import Foundation

/// Beschreibende Angaben aus dem Quelldokument, soweit das Format sie kennt.
///
/// Jeder Adapter füllt nur, was er sicher lesen kann; alles andere bleibt
/// `nil`. Leere Zeichenketten gelten als „nicht vorhanden“, damit ein
/// Word-Dokument mit leerem Titelfeld keinen leeren Frontmatter-Eintrag erzeugt.
public struct DocumentMetadata: Codable, Equatable, Sendable {
    public var title: String?
    public var author: String?
    public var subject: String?
    public var description: String?
    public var keywords: [String]
    public var created: Date?
    public var modified: Date?

    public init(
        title: String? = nil,
        author: String? = nil,
        subject: String? = nil,
        description: String? = nil,
        keywords: [String] = [],
        created: Date? = nil,
        modified: Date? = nil
    ) {
        self.title = Self.cleaned(title)
        self.author = Self.cleaned(author)
        self.subject = Self.cleaned(subject)
        self.description = Self.cleaned(description)
        self.keywords = keywords.compactMap(Self.cleaned)
        self.created = created
        self.modified = modified
    }

    public var isEmpty: Bool {
        title == nil && author == nil && subject == nil && description == nil
            && keywords.isEmpty && created == nil && modified == nil
    }

    /// YAML-Frontmatter für den Anfang der Markdown-Datei; `nil` ohne Angaben.
    /// Alle Werte stehen in doppelten Anführungszeichen, damit ein Titel wie
    /// `Bericht: Q3` oder `#1` kein YAML-Konstrukt auslöst.
    public var frontmatter: String? {
        guard !isEmpty else {
            return nil
        }
        var lines = ["---"]
        if let title { lines.append("title: \(Self.yamlString(title))") }
        if let author { lines.append("author: \(Self.yamlString(author))") }
        if let subject { lines.append("subject: \(Self.yamlString(subject))") }
        if let description { lines.append("description: \(Self.yamlString(description))") }
        if !keywords.isEmpty {
            lines.append("keywords: [" + keywords.map(Self.yamlString).joined(separator: ", ") + "]")
        }
        if let created { lines.append("created: \(Self.iso8601(created))") }
        if let modified { lines.append("modified: \(Self.iso8601(modified))") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Nur die vorhandenen Felder als Wörterbuch, für die JSON-Ausgabe der CLI.
    public var jsonFields: [String: Any] {
        var fields = [String: Any]()
        if let title { fields["title"] = title }
        if let author { fields["author"] = author }
        if let subject { fields["subject"] = subject }
        if let description { fields["description"] = description }
        if !keywords.isEmpty { fields["keywords"] = keywords }
        if let created { fields["created"] = Self.iso8601(created) }
        if let modified { fields["modified"] = Self.iso8601(modified) }
        return fields
    }

    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func yamlString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Whitespace kürzen; ein Wert, der danach leer ist, existiert nicht.
    static func cleaned(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Schlüsselwörter, wie Office sie schreibt: durch Komma oder Semikolon
    /// getrennt in einem Feld.
    static func splitKeywords(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// W3CDTF/ISO-8601 mit und ohne Zeitzone; ohne Zone gilt UTC, denn die
    /// Quelle verrät die Zone nicht und ein Datum ist besser als keines.
    static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let withTime = ISO8601DateFormatter()
        withTime.formatOptions = [.withInternetDateTime]
        if let date = withTime.date(from: trimmed) {
            return date
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) {
            return date
        }
        // Ohne Zone: als UTC lesen.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}

/// Liest `docProps/core.xml` (OOXML: DOCX, XLSX, PPTX) und `meta.xml`
/// (OpenDocument: ODT, ODS, ODM). Beide nutzen Dublin Core für Titel, Autor,
/// Thema und Beschreibung; nur Daten und Schlüsselwörter heißen anders.
enum PackageMetadataParser {
    static let dublinCore = "http://purl.org/dc/elements/1.1/"
    static let dcTerms = "http://purl.org/dc/terms/"
    static let coreProperties = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    static let odfMeta = "urn:oasis:names:tc:opendocument:xmlns:meta:1.0"

    /// Liest den Metadaten-Eintrag aus einem bereits geprüften Paket. Fehlt er
    /// oder ist er unlesbar, gibt es keine Angaben — nie einen Fehler.
    static func read(fromPackageAt url: URL, entryName: String) -> DocumentMetadata {
        guard let package = try? ZIPArchiveInspector.packageContents(at: url, entryNames: [entryName]),
              let xml = package.entries[entryName] else {
            return DocumentMetadata()
        }
        return parse(xml)
    }

    static func read(from reader: ZIPPackageReader, entryName: String) -> DocumentMetadata {
        guard let xml = try? reader.dataIfPresent(named: entryName) else { return DocumentMetadata() }
        return parse(xml)
    }

    static func parse(_ xml: Data) -> DocumentMetadata {
        let delegate = Delegate()
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        // Ein kaputtes Metadaten-XML ist kein Grund, das Dokument abzulehnen:
        // Dann gibt es eben keine Angaben.
        _ = parser.parse()
        return delegate.result()
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private var current: (namespace: String, name: String)?
        private var text = ""
        private var values = [String: String]()
        private var keywords = [String]()

        func result() -> DocumentMetadata {
            var allKeywords = keywords
            if let combined = values["keywords"] {
                allKeywords.append(contentsOf: DocumentMetadata.splitKeywords(combined))
            }
            return DocumentMetadata(
                title: values["title"],
                author: values["creator"] ?? values["initial-creator"],
                subject: values["subject"],
                description: values["description"],
                keywords: allKeywords,
                created: (values["created"] ?? values["creation-date"]).flatMap(DocumentMetadata.parseDate),
                modified: (values["modified"] ?? values["date"]).flatMap(DocumentMetadata.parseDate)
            )
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            current = (namespaceURI ?? "", elementName)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            defer { current = nil }
            guard let current, current.name == elementName else {
                return
            }
            let value = text
            switch (current.namespace, current.name) {
            case (PackageMetadataParser.dublinCore, "title"), (PackageMetadataParser.dublinCore, "creator"),
                 (PackageMetadataParser.dublinCore, "subject"), (PackageMetadataParser.dublinCore, "description"):
                // Erster Wert gewinnt; ODF erlaubt mehrere `dc:creator`, dann
                // ist der erste der Verfasser der letzten Änderung, und der
                // eigentliche Autor steht in `meta:initial-creator`.
                if values[current.name] == nil {
                    values[current.name] = value
                }
            case (PackageMetadataParser.dublinCore, "date"):
                values["date"] = value
            case (PackageMetadataParser.dcTerms, "created"), (PackageMetadataParser.dcTerms, "modified"):
                values[current.name] = value
            case (PackageMetadataParser.coreProperties, "keywords"):
                values["keywords"] = value
            case (PackageMetadataParser.odfMeta, "initial-creator"), (PackageMetadataParser.odfMeta, "creation-date"):
                values[current.name] = value
            case (PackageMetadataParser.odfMeta, "keyword"):
                if let keyword = DocumentMetadata.cleaned(value) {
                    keywords.append(keyword)
                }
            default:
                break
            }
        }
    }
}

/// Liest die `\info`-Gruppe eines RTF-Dokuments: `{\info{\title …}{\author …}
/// {\subject …}{\keywords …}{\doccomm …}{\creatim\yr…\mo…\dy…\hr…\min…}}`.
/// Der Leser folgt nur der Gruppenklammerung und kennt die Escapes `\'hh`,
/// `\uN?` und `\{ \} \\`; mehr braucht der Info-Block nicht.
enum RTFInfoParser {
    /// Höchstens so viele Bytes werden nach `\info` durchsucht. Die Gruppe
    /// steht im Kopf, weit vor dem Text; ein 200-MB-Dokument bleibt so billig.
    static let searchLimit = 262_144

    /// Liest höchstens `searchLimit` Bytes vom Anfang der Datei.
    static func read(from url: URL) -> DocumentMetadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return DocumentMetadata()
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: searchLimit) else {
            return DocumentMetadata()
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> DocumentMetadata {
        let bytes = [UInt8](data.prefix(searchLimit))
        guard let infoStart = find([UInt8]("\\info".utf8), in: bytes) else {
            return DocumentMetadata()
        }
        var index = infoStart + 5
        var depth = 0
        var groups = [(name: String, start: Int, end: Int)]()
        var groupStack = [(name: String, start: Int)]()
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count,
               bytes[index + 1] == UInt8(ascii: "{") || bytes[index + 1] == UInt8(ascii: "}")
                || bytes[index + 1] == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if byte == UInt8(ascii: "{") {
                depth += 1
                let nameEnd = controlWordEnd(in: bytes, from: index + 1)
                let name = String(decoding: bytes[(index + 1)..<nameEnd], as: UTF8.self)
                groupStack.append((name, nameEnd))
                index += 1
                continue
            }
            if byte == UInt8(ascii: "}") {
                if depth == 0 {
                    break
                }
                depth -= 1
                if let group = groupStack.popLast(), depth == 0 {
                    groups.append((group.name, group.start, index))
                }
                index += 1
                continue
            }
            index += 1
        }

        var metadata = DocumentMetadata()
        for group in groups {
            let body = Array(bytes[group.start..<group.end])
            switch group.name {
            case "\\title": metadata.title = DocumentMetadata.cleaned(decodeText(body))
            case "\\author": metadata.author = DocumentMetadata.cleaned(decodeText(body))
            case "\\subject": metadata.subject = DocumentMetadata.cleaned(decodeText(body))
            case "\\doccomm": metadata.description = DocumentMetadata.cleaned(decodeText(body))
            case "\\keywords": metadata.keywords = DocumentMetadata.splitKeywords(decodeText(body))
            case "\\creatim": metadata.created = decodeDate(body)
            case "\\revtim": metadata.modified = decodeDate(body)
            default: break
            }
        }
        return metadata
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else {
            return nil
        }
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            // Nur das ganze Steuerwort: `\infoX` wäre ein anderes.
            let next = start + needle.count
            if next < haystack.count, isAlpha(haystack[next]) {
                continue
            }
            return start
        }
        return nil
    }

    private static func controlWordEnd(in bytes: [UInt8], from start: Int) -> Int {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "\\") else {
            return start
        }
        var index = start + 1
        while index < bytes.count, isAlpha(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func isAlpha(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// Text einer Gruppe: Steuerwörter überspringen, Escapes auflösen.
    ///
    /// `\uN` liefert UTF-16-Codeeinheiten, keine Unicode-Skalare: Ein Zeichen
    /// außerhalb der BMP (etwa ein Emoji) kommt als zwei `\uN` mit negativen
    /// Zahlen. Die Einheiten werden gesammelt und erst als Paar dekodiert.
    /// `\ucN` legt fest, wie viele Ersatzzeichen nach jedem `\uN` zu
    /// überspringen sind (Standard 1, `\uc0` keins); vorher galt immer 1 und
    /// Surrogate gingen verloren (Review-Funde 2026-09-03).
    static func decodeText(_ body: [UInt8]) -> String {
        var scalars = [UInt8]()
        var utf16Units = [UInt16]()
        var result = ""
        var index = 0
        var fallbackCount = 1
        var skipAfterUnicode = 0
        func flushBytes() {
            guard !scalars.isEmpty else {
                return
            }
            result += String(decoding: scalars, as: UTF8.self)
            scalars.removeAll()
        }
        func flushUTF16() {
            guard !utf16Units.isEmpty else {
                return
            }
            result += decodeUTF16(utf16Units)
            utf16Units.removeAll()
        }
        /// Verbraucht ein Ersatzzeichen nach `\uN`; `true`, wenn es wegfällt.
        func consumeFallback() -> Bool {
            guard skipAfterUnicode > 0 else {
                return false
            }
            skipAfterUnicode -= 1
            return true
        }
        while index < body.count {
            let byte = body[index]
            if byte == UInt8(ascii: "\\"), index + 1 < body.count {
                let next = body[index + 1]
                if next == UInt8(ascii: "'"), index + 3 < body.count,
                   let value = UInt8(String(decoding: body[(index + 2)...(index + 3)], as: UTF8.self), radix: 16) {
                    if !consumeFallback() {
                        flushBytes()
                        flushUTF16()
                        result += windows1252Character(value)
                    }
                    index += 4
                    continue
                }
                if next == UInt8(ascii: "{") || next == UInt8(ascii: "}") || next == UInt8(ascii: "\\") {
                    if !consumeFallback() {
                        flushUTF16()
                        scalars.append(next)
                    }
                    index += 2
                    continue
                }
                if next == UInt8(ascii: "u"), index + 2 < body.count,
                   body[index + 2] == UInt8(ascii: "-") || isDigit(body[index + 2]) {
                    var end = index + 2
                    var negative = false
                    if body[end] == UInt8(ascii: "-") {
                        negative = true
                        end += 1
                    }
                    let digitsStart = end
                    while end < body.count, isDigit(body[end]) {
                        end += 1
                    }
                    if end > digitsStart, let number = Int(String(decoding: body[digitsStart..<end], as: UTF8.self)) {
                        flushBytes()
                        // RTF schreibt Einheiten ab 32768 als negative Zahl:
                        // `\u-10180` ist 65536 − 10180 = 0xD83C. Vorher wurde
                        // addiert, was für jedes negative `\uN` ein falsches
                        // Zeichen ergab.
                        let unit = negative ? 65_536 - number : number
                        if (0...0xFFFF).contains(unit) {
                            utf16Units.append(UInt16(unit))
                        }
                        skipAfterUnicode = fallbackCount
                        if end < body.count, body[end] == UInt8(ascii: " ") {
                            end += 1
                        }
                        index = end
                        continue
                    }
                }
                if isAlpha(next) {
                    // Sonstiges Steuerwort samt Zahl und einem Leerzeichen;
                    // nur `\ucN` verändert den Zustand des Dekoders.
                    var end = index + 1
                    while end < body.count, isAlpha(body[end]) {
                        end += 1
                    }
                    let word = String(decoding: body[(index + 1)..<end], as: UTF8.self)
                    let numberStart = end
                    if end < body.count, body[end] == UInt8(ascii: "-") {
                        end += 1
                    }
                    while end < body.count, isDigit(body[end]) {
                        end += 1
                    }
                    if word == "uc", let count = Int(String(decoding: body[numberStart..<end], as: UTF8.self)), count >= 0 {
                        fallbackCount = count
                    }
                    if end < body.count, body[end] == UInt8(ascii: " ") {
                        end += 1
                    }
                    index = end
                    continue
                }
                index += 2
                continue
            }
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") {
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n") {
                index += 1
                continue
            }
            if consumeFallback() {
                index += 1
                continue
            }
            flushUTF16()
            scalars.append(byte)
            index += 1
        }
        flushBytes()
        flushUTF16()
        return result
    }

    /// UTF-16-Einheiten zu Text; ein Surrogat ohne Partner fällt weg.
    private static func decodeUTF16(_ units: [UInt16]) -> String {
        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < units.count {
            let unit = units[index]
            if UTF16.isLeadSurrogate(unit), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
                let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00)
                if let scalar = Unicode.Scalar(value) {
                    scalars.append(scalar)
                }
                index += 2
                continue
            }
            if let scalar = Unicode.Scalar(unit) {
                scalars.append(scalar)
            }
            index += 1
        }
        return String(scalars)
    }

    private static func windows1252Character(_ value: UInt8) -> String {
        String(data: Data([value]), encoding: .windowsCP1252) ?? ""
    }

    /// `\yr2026\mo9\dy2\hr10\min5` → Datum in UTC; RTF kennt keine Zone.
    static func decodeDate(_ body: [UInt8]) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        let text = String(decoding: body, as: UTF8.self)
        var found = false
        for (word, keyPath) in [
            ("\\yr", \DateComponents.year), ("\\mo", \DateComponents.month),
            ("\\dy", \DateComponents.day), ("\\hr", \DateComponents.hour),
            ("\\min", \DateComponents.minute), ("\\sec", \DateComponents.second),
        ] as [(String, WritableKeyPath<DateComponents, Int?>)] {
            guard let range = text.range(of: word) else {
                continue
            }
            let digits = text[range.upperBound...].prefix { $0.isNumber }
            guard let number = Int(digits) else {
                continue
            }
            components[keyPath: keyPath] = number
            found = true
        }
        guard found, components.year != nil, components.month != nil, components.day != nil else {
            return nil
        }
        return components.date
    }
}
