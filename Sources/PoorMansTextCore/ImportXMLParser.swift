import Foundation
#if os(Linux)
import FoundationXML
#endif

/// Ein `XMLParser`, wie ihn jeder Leser eines fremden Dokumentpakets braucht.
///
/// Die drei Einstellungen standen vorher an acht Stellen einzeln, siebenmal
/// wortgleich — und an der achten fehlte die wichtigste (Review-Fund
/// 2026-09-10). Hier stehen sie einmal:
///
/// - **Namensraumverarbeitung.** Ohne sie liefert `XMLParser` den Elementnamen
///   samt Präfix (`r:Relationship`), und ein Paket mit einem anderen — aber
///   völlig gültigen — Präfix rutscht an jeder Namensprüfung vorbei. Mit ihr ist
///   `elementName` der lokale Name.
/// - **Gemeldete Präfixdeklarationen.** Attributnamen behalten ihr Präfix auch
///   dann. Damit ein Delegate es auflösen kann, meldet
///   `shouldReportNamespacePrefixes` zusätzlich jede Präfix-Deklaration; ohne
///   dieses Flag ruft `XMLParser` die zugehörigen Delegate-Methoden gar nicht
///   erst auf. In die Attributliste geraten die `xmlns`-Deklarationen dadurch
///   nicht.
/// - **Keine externen Entitäten.** Ein fremdes Paket darf über eine
///   Entitätsdeklaration nichts nachladen. Foundation stellt das zwar auf
///   `false` vor; als Sicherheitseigenschaft gehört sie trotzdem in den Code
///   und nicht in eine Voreinstellung.
enum ImportXMLParser {
    static func make(_ xml: Data, delegate: any XMLParserDelegate) -> XMLParser {
        #if os(Linux)
        let parser = LinuxImportXMLParser(data: xml)
        // Linux meldet interne Entitätsdeklarationen nicht verlässlich an Delegates.
        parser.rejectionReason = LinuxImportXMLParser.rejectionReason(for: xml)
        #else
        let parser = XMLParser(data: xml)
        #endif
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        return parser
    }
}

#if os(Linux)
private final class LinuxImportXMLParser: XMLParser {
    private static let encodingExpression = try? NSRegularExpression(
        pattern: #"encoding\s*=\s*['"]([A-Za-z][A-Za-z0-9._-]*)['"]"#)
    var rejectionReason: String?
    private var rejection: Error?

    override var parserError: Error? { rejection ?? super.parserError }

    override func parse() -> Bool {
        if let rejectionReason {
            rejection = NSError(domain: "NSXMLParserErrorDomain", code: 1,
                userInfo: [NSLocalizedDescriptionKey: rejectionReason])
            return false
        }
        // FoundationXML kann trotz eines gemeldeten Syntaxfehlers true zurückgeben.
        let parsed = super.parse()
        return parsed && parserError == nil
    }

    static func rejectionReason(for data: Data) -> String? {
        let signature = Array(data.prefix(4))
        let encoding: String.Encoding?
        if signature.starts(with: [0, 0, 0xFE, 0xFF]) || signature == [0, 0, 0, 0x3C] { encoding = .utf32BigEndian }
        else if signature.starts(with: [0xFF, 0xFE, 0, 0]) || signature == [0x3C, 0, 0, 0] { return "unsupported XML encoding: UTF-32LE" }
        else if signature.starts(with: [0xFE, 0xFF]) || signature.starts(with: [0, 0x3C]) { encoding = .utf16BigEndian }
        else if signature.starts(with: [0xFF, 0xFE]) || signature.starts(with: [0x3C, 0]) { encoding = .utf16LittleEndian }
        else { encoding = nil }
        let text = encoding.flatMap { String(data: data, encoding: $0) } ?? String(decoding: data, as: UTF8.self)
        var remaining = text[...].drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        // Shiftencodings können XML-Syntaxzeichen vor diesem Vorabcheck verbergen.
        guard remaining.hasPrefix("<") else { return "unsupported XML encoding" }

        while !remaining.isEmpty {
            remaining = remaining.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
            if remaining.hasPrefix("<!--") {
                guard let end = remaining.range(of: "-->") else { return nil }
                remaining = remaining[end.upperBound...]
            } else if remaining.hasPrefix("<?") {
                guard let end = remaining.range(of: "?>") else { return nil }
                if remaining.hasPrefix("<?xml"), remaining.dropFirst(5).first?.isWhitespace == true {
                    let declaration = String(remaining[..<end.upperBound])
                    guard let expression = encodingExpression else {
                        return "XML encoding declaration could not be checked"
                    }
                    let range = NSRange(declaration.startIndex..., in: declaration)
                    if let match = expression.firstMatch(in: declaration, range: range),
                       let nameRange = Range(match.range(at: 1), in: declaration) {
                        let name = declaration[nameRange].uppercased()
                        let allowed: Set<String> = ["UTF-8", "UTF-16", "UTF-16LE", "UTF-16BE",
                                                "UTF-32BE", "US-ASCII",
                                                "ISO-8859-1", "WINDOWS-1252"]
                        guard allowed.contains(name) else { return "unsupported XML encoding: " + name.prefix(64) }
                    }
                }
                remaining = remaining[end.upperBound...]
            } else if remaining.hasPrefix("<!DOCTYPE") {
                var quote: Character?
                for character in remaining.dropFirst(9) {
                    if let delimiter = quote {
                        if character == delimiter { quote = nil }
                    } else if character == "\"" || character == "'" { quote = character }
                    else if character == "[" { return "XML internal subsets are not supported" }
                    else if character == ">" { return nil }
                }
                return nil
            } else { return nil }
        }
        return nil
    }
}
#endif
