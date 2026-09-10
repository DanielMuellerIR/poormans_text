import Foundation

enum WordProcessingPackageKind {
    case document
    case macroEnabledDocument
    case template
    case macroEnabledTemplate

    var containsMacros: Bool {
        self == .macroEnabledDocument || self == .macroEnabledTemplate
    }

    var isTemplate: Bool {
        self == .template || self == .macroEnabledTemplate
    }
}

struct WordProcessingPackageInspection {
    let format: InputFormat
    let packageKind: WordProcessingPackageKind?
    let containsComments: Bool
    let containsTrackedChanges: Bool
    let unsafeImageReferences: [String]

    var warnings: [ConversionWarning] {
        var result = [ConversionWarning]()
        if packageKind?.containsMacros == true {
            result.append(.wordProcessingMacrosNotPreserved)
        }
        if packageKind?.isTemplate == true {
            result.append(.wordProcessingTemplateSemanticsNotPreserved)
        }
        if containsComments {
            result.append(.wordProcessingCommentsNotPreserved)
        }
        if containsTrackedChanges {
            result.append(
                format == .docx
                    ? .wordProcessingChangesAccepted
                    : .openDocumentChangesNotPreserved
            )
        }
        return result
    }
}

/// Formatwissen für DOCX und ODT; die ZIP- und Ressourcenprüfung besitzt der Leser.
enum WordProcessingPackageInspector {
    static func inspect(at inputURL: URL) throws -> WordProcessingPackageInspection? {
        try inspect(reader: ZIPArchiveInspector.inspectionSnapshot(at: inputURL))
    }

    static func inspect(
        reader: any ZIPPackageReading
    ) throws -> WordProcessingPackageInspection? {
        let entryNames = reader.entryNames

        if entryNames.contains("[Content_Types].xml"),
           let mainPart = try mainDocumentPart(reader: reader, entryNames: entryNames) {
            let packageKind = try WordprocessingContentTypesParser.packageKind(
                in: try reader.data(named: "[Content_Types].xml"),
                mainPart: mainPart
            )
            let document = try WordprocessingContentParser.inspect(
                try reader.data(named: mainPart)
            )
            guard document.hasDocumentRoot else {
                throw InspectionError("\(mainPart) has no valid WordprocessingML document root")
            }
            // Kommentare, Fuß- und Endnoten liegen neben dem Hauptteil; bei
            // `word/document2.xml` also weiter unter `word/`.
            let partDirectory = (mainPart as NSString).deletingLastPathComponent
            func siblingPart(_ name: String) -> String {
                partDirectory.isEmpty ? name : "\(partDirectory)/\(name)"
            }
            let commentDefinitions = try reader.dataIfPresent(named: siblingPart("comments.xml"))
                .map { try WordprocessingContentParser.inspect($0).containsCommentDefinitions }
                ?? false
            let comments = document.containsCommentAnchors || commentDefinitions
            // Fuß- und Endnoten gehören zum selben Dokument: Pandoc liest sie
            // mit und wendet `--track-changes=accept` auch dort an. Wurde nur
            // dort etwas nachverfolgt, nahm die Umwandlung die Änderung still
            // an — ohne die Warnung, für die es sie gibt
            // (Review-Fund 2026-09-10).
            var changes = document.containsTrackedChanges
            for name in [siblingPart("footnotes.xml"), siblingPart("endnotes.xml")] where !changes {
                guard let xml = try reader.dataIfPresent(named: name) else {
                    continue
                }
                changes = try WordprocessingContentParser.inspect(xml).containsTrackedChanges
            }
            let externalImages = try entryNames.sorted()
                .filter { $0.hasSuffix(".rels") }
                .flatMap { name -> [String] in
                    let xml = try reader.data(named: name)
                    return try ExternalImageRelationshipParser.targets(in: xml)
                }

            return WordProcessingPackageInspection(
                format: .docx,
                packageKind: packageKind,
                containsComments: comments,
                containsTrackedChanges: changes,
                unsafeImageReferences: externalImages.sorted()
            )
        }

        if entryNames.contains("mimetype"),
           entryNames.contains("content.xml"),
           try reader.string(named: "mimetype")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == "application/vnd.oasis.opendocument.text" {
            let parsed = try ODTContentParser.inspect(try reader.data(named: "content.xml"))
            // Ein `draw:image` mit externem Ziel kann auch in `styles.xml`
            // stehen (Kopf-/Fußzeilen, Master-Pages). Pandoc gibt diese
            // Inhalte heute nicht aus; die Prüfung auf entfernte Ziele gilt
            // trotzdem für das ganze Paket (Roadmap-Punkt, 2026-09-10).
            let styleImages = try reader.dataIfPresent(named: "styles.xml")
                .map { try ODTContentParser.inspect($0).externalImageReferences } ?? []
            return WordProcessingPackageInspection(
                format: .odt,
                packageKind: nil,
                containsComments: parsed.containsAnnotations,
                containsTrackedChanges: parsed.containsTrackedChanges,
                unsafeImageReferences: (parsed.externalImageReferences + styleImages).sorted()
            )
        }

        return nil
    }

    /// Der Hauptteil eines OOXML-Pakets laut OPC: das Ziel der
    /// `officeDocument`-Beziehung in `_rels/.rels`. So löst auch Pandoc auf;
    /// ein von Word repariertes Dokument trägt etwa `word/document2.xml` und
    /// wurde vorher abgelehnt (Roadmap-Punkt, 2026-09-10). Ohne `_rels/.rels`
    /// gilt weiterhin `word/document.xml`. Fehlt das Ziel im Paket, ist es
    /// kein lesbares Word-Dokument (`nil`). Ob der Teil wirklich
    /// WordprocessingML ist, entscheiden danach Content-Type und Wurzelelement.
    private static func mainDocumentPart(
        reader: any ZIPPackageReading,
        entryNames: Set<String>
    ) throws -> String? {
        guard let rootRelationships = try reader.dataIfPresent(named: "_rels/.rels") else {
            return entryNames.contains("word/document.xml") ? "word/document.xml" : nil
        }
        guard let target = try OfficeDocumentRelationshipParser.target(in: rootRelationships) else {
            return nil
        }
        // OPC erlaubt Ziele mit und ohne führenden Schrägstrich, immer
        // relativ zur Paketwurzel.
        let partName = target.hasPrefix("/") ? String(target.dropFirst()) : target
        return entryNames.contains(partName) ? partName : nil
    }

    private struct InspectionError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

/// Startet einen XML-Lauf und wirft, wenn das Paket-XML defekt ist. Die
/// Einstellungen des Parsers stehen in `ImportXMLParser`.
private func parseXML(_ xml: Data, with delegate: XMLParserDelegate) throws {
    let parser = ImportXMLParser.make(xml, delegate: delegate)
    let parsedSuccessfully = parser.parse()
    try ConversionExecution.check()
    guard parsedSuccessfully else {
        throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
    }
}

/// Der Wert eines laut OPC unpräfigierten Attributs.
///
/// Der XML-Standard legt unpräfigierte Attribute in keinen Namensraum. Deshalb
/// darf ein fremdes `foo:PartName` oder `foo:Target` nicht allein wegen seines
/// gleichen Suffixes als OPC-Attribut gelten.
private func attributeValue(
    localName: String,
    in attributes: [String: String]
) -> String? {
    attributes[localName]
}

/// Die Namensräume, deren Elemente die Paketprüfung auswerten darf.
private enum InspectedNamespaces {
    static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    static let drawing = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
    static let xlink = "http://www.w3.org/1999/xlink"
    static let wordprocessing: Set<String> = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main",
    ]
}

/// Das Ziel der `officeDocument`-Beziehung aus `_rels/.rels`; `nil`, wenn es
/// keine gibt. Mehrere solche Beziehungen sind kein gültiges Paket.
private enum OfficeDocumentRelationshipParser {
    static func target(in xml: Data) throws -> String? {
        let delegate = RelationshipDelegate()
        try parseXML(xml, with: delegate)
        guard delegate.targets.count <= 1 else {
            throw RelationshipError("_rels/.rels declares more than one officeDocument relationship")
        }
        return delegate.targets.first
    }

    private final class RelationshipDelegate: NSObject, XMLParserDelegate {
        var targets = [String]()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            guard elementName == "Relationship",
                  namespaceURI == "http://schemas.openxmlformats.org/package/2006/relationships",
                  attributeValue(localName: "TargetMode", in: attributeDict)?.lowercased()
                    != "external",
                  attributeValue(localName: "Type", in: attributeDict)?
                    .lowercased().hasSuffix("/officedocument") == true,
                  let target = attributeValue(localName: "Target", in: attributeDict) else {
                return
            }
            targets.append(target)
        }
    }

    private struct RelationshipError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

private enum ExternalImageRelationshipParser {
    static func targets(in xml: Data) throws -> [String] {
        // Ein leerer Beziehungsteil kann kein externes Ziel verbergen und
        // gilt deshalb als leer, nicht als defekt. Ein nicht leerer, aber
        // unlesbarer Teil bleibt ein Ablehnungsgrund — auch bei Teilen, die
        // Pandoc nie liest: Sonst wäre die Prüfung auf externe Bildziele an
        // genau dieser Stelle blind (Entscheidung, Roadmap-Punkt 2026-09-10).
        guard !xml.isEmpty else { return [] }
        let delegate = RelationshipDelegate()
        try parseXML(xml, with: delegate)
        return delegate.targets
    }

    private final class RelationshipDelegate: NSObject, XMLParserDelegate {
        var targets = [String]()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            guard elementName == "Relationship",
                  attributeValue(localName: "TargetMode", in: attributeDict)?.lowercased()
                    == "external",
                  attributeValue(localName: "Type", in: attributeDict)?
                    .lowercased().hasSuffix("/image") == true,
                  let target = attributeValue(localName: "Target", in: attributeDict) else {
                return
            }
            targets.append(target)
        }
    }
}

/// Liest den Typ des Word-Hauptteils aus dem dafür verbindlichen
/// `[Content_Types].xml`. So werden DOCM und DOTX nicht still wie ein normales
/// DOCX behandelt, und ein beliebiges ZIP mit `word/document.xml` reicht nicht
/// mehr als Formaterkennung aus.
private enum WordprocessingContentTypesParser {
    static func packageKind(in xml: Data, mainPart: String) throws -> WordProcessingPackageKind {
        let delegate = ContentTypesDelegate(mainPart: mainPart)
        try parseXML(xml, with: delegate)
        guard delegate.hasValidRoot else {
            throw ContentTypeError("[Content_Types].xml has no valid Types root")
        }
        guard delegate.mainContentTypes.count == 1,
              let contentType = delegate.mainContentTypes.first else {
            throw ContentTypeError(
                "[Content_Types].xml must declare exactly one content type for \(mainPart)"
            )
        }

        return switch contentType.lowercased() {
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml":
            .document
        case "application/vnd.ms-word.document.macroenabled.main+xml":
            .macroEnabledDocument
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml":
            .template
        case "application/vnd.ms-word.template.macroenabledtemplate.main+xml":
            .macroEnabledTemplate
        default:
            throw ContentTypeError(
                "\(mainPart) has an unsupported main content type: \(contentType)"
            )
        }
    }

    private final class ContentTypesDelegate: NSObject, XMLParserDelegate {
        var hasValidRoot = false
        var mainContentTypes = Set<String>()
        private var sawRoot = false
        private let mainPartName: String

        init(mainPart: String) {
            mainPartName = "/" + mainPart
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            if !sawRoot {
                sawRoot = true
                hasValidRoot = elementName == "Types"
                    && namespaceURI == "http://schemas.openxmlformats.org/package/2006/content-types"
            }
            guard namespaceURI == "http://schemas.openxmlformats.org/package/2006/content-types",
                  elementName == "Override",
                  let partName = attributeValue(localName: "PartName", in: attributeDict),
                  "/" + partName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    == mainPartName,
                  let contentType = attributeValue(
                    localName: "ContentType",
                    in: attributeDict
                  ) else {
                return
            }
            mainContentTypes.insert(contentType)
        }
    }

    private struct ContentTypeError: LocalizedError {
        let reason: String

        init(_ reason: String) {
            self.reason = reason
        }

        var errorDescription: String? { reason }
    }
}

private struct WordprocessingContentInspection {
    let rootElementName: String?
    let rootNamespaceURI: String?
    let containsCommentAnchors: Bool
    let containsCommentDefinitions: Bool
    let containsTrackedChanges: Bool

    var hasDocumentRoot: Bool {
        guard rootElementName == "document", let rootNamespaceURI else {
            return false
        }
        return InspectedNamespaces.wordprocessing.contains(rootNamespaceURI)
    }
}

/// Zählt WordprocessingML-Elemente über ihren exakten lokalen Namen und ihren
/// Namensraum.
///
/// Eine Teilstringsuche nach `<w:ins` trifft auch den ganz gewöhnlichen
/// Feldcode `<w:instrText>`; ein Dokument mit Inhaltsverzeichnis oder Seitenzahl
/// bekäme dann die falsche Warnung, nachverfolgte Änderungen seien angenommen
/// worden. Und ein `ins`-Element aus einem fremden Namensraum — etwa aus
/// eingebettetem HTML — ist überhaupt keine nachverfolgte Änderung.
private enum WordprocessingContentParser {
    static func inspect(_ xml: Data) throws -> WordprocessingContentInspection {
        let delegate = ContentDelegate()
        try parseXML(xml, with: delegate)
        return WordprocessingContentInspection(
            rootElementName: delegate.rootElementName,
            rootNamespaceURI: delegate.rootNamespaceURI,
            containsCommentAnchors: delegate.containsCommentAnchors,
            containsCommentDefinitions: delegate.containsCommentDefinitions,
            containsTrackedChanges: delegate.containsTrackedChanges
        )
    }

    private final class ContentDelegate: NSObject, XMLParserDelegate {
        var containsCommentAnchors = false
        var containsCommentDefinitions = false
        var containsTrackedChanges = false
        var rootElementName: String?
        var rootNamespaceURI: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            if rootElementName == nil {
                rootElementName = elementName
                rootNamespaceURI = namespaceURI
            }
            guard let namespaceURI,
                  InspectedNamespaces.wordprocessing.contains(namespaceURI) else {
                return
            }
            switch elementName {
            case "commentRangeStart":
                containsCommentAnchors = true
            case "comment":
                containsCommentDefinitions = true
            // Auch reine Formatänderungen sind nachverfolgte Änderungen: Wurde
            // mit eingeschalteter Verfolgung nur formatiert, fehlte die Warnung
            // ganz (Review-Fund 2026-09-10).
            case "ins", "del", "moveFrom", "moveTo",
                 "rPrChange", "pPrChange", "sectPrChange", "numberingChange",
                 "tblPrChange", "trPrChange", "tcPrChange", "tblGridChange",
                 "cellIns", "cellDel", "cellMerge":
                containsTrackedChanges = true
            default:
                break
            }
        }
    }
}

private struct ODTContentInspection {
    let containsAnnotations: Bool
    let containsTrackedChanges: Bool
    let externalImageReferences: [String]
}

private enum ODTContentParser {
    static func inspect(_ xml: Data) throws -> ODTContentInspection {
        let delegate = ContentDelegate()
        try parseXML(xml, with: delegate)
        return ODTContentInspection(
            containsAnnotations: delegate.containsAnnotations,
            containsTrackedChanges: delegate.containsTrackedChanges,
            externalImageReferences: delegate.externalImages
        )
    }

    private final class ContentDelegate: NSObject, XMLParserDelegate {
        var containsAnnotations = false
        var containsTrackedChanges = false
        var externalImages = [String]()
        private let prefixes = NamespacePrefixTracker()

        func parser(
            _ parser: XMLParser,
            didStartMappingPrefix prefix: String,
            toURI namespaceURI: String
        ) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            prefixes.startMapping(prefix: prefix, uri: namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            prefixes.endMapping(prefix: prefix)
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if ConversionExecution.isCancelled { parser.abortParsing(); return }
            // Jedes Element zählt nur in seinem ODF-Namensraum. Ein fremdes
            // `foo:image` oder `foo:annotation` ist kein ODF-Bild und keine
            // ODF-Notiz und darf deshalb keine Warnung oder Ablehnung auslösen.
            guard let namespaceURI else { return }
            switch (namespaceURI, elementName) {
            case (InspectedNamespaces.office, "annotation"):
                containsAnnotations = true
            case (InspectedNamespaces.text, "tracked-changes"):
                containsTrackedChanges = true
            case (InspectedNamespaces.drawing, "image"):
                guard let reference = prefixes.attributeValue(
                    localName: "href",
                    namespaceURI: InspectedNamespaces.xlink,
                    in: attributeDict
                ), isUnsafe(reference) else {
                    return
                }
                externalImages.append(reference)
            default:
                break
            }
        }

        private func isUnsafe(_ reference: String) -> Bool {
            guard !reference.isEmpty else {
                return true
            }
            if let url = URL(string: reference), url.scheme != nil {
                return true
            }
            let components = NSString(string: reference).pathComponents
            return reference.hasPrefix("/")
                || reference.contains("\\")
                || components.contains("..")
        }
    }
}

