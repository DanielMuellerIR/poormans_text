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
           entryNames.contains("word/document.xml") {
            let packageKind = try WordprocessingContentTypesParser.packageKind(
                in: try reader.data(named: "[Content_Types].xml")
            )
            let document = try WordprocessingContentParser.inspect(
                try reader.data(named: "word/document.xml")
            )
            guard document.hasDocumentRoot else {
                throw InspectionError("word/document.xml has no valid WordprocessingML document root")
            }
            let commentDefinitions = entryNames.contains("word/comments.xml")
                ? try WordprocessingContentParser.inspect(
                    try reader.data(named: "word/comments.xml")
                ).containsCommentDefinitions
                : false
            let comments = document.containsCommentAnchors || commentDefinitions
            let changes = document.containsTrackedChanges
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
            return WordProcessingPackageInspection(
                format: .odt,
                packageKind: nil,
                containsComments: parsed.containsAnnotations,
                containsTrackedChanges: parsed.containsTrackedChanges,
                unsafeImageReferences: parsed.externalImageReferences.sorted()
            )
        }

        return nil
    }

    private struct InspectionError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

/// Startet einen XML-Lauf mit Namensraumverarbeitung.
///
/// Ohne sie liefert `XMLParser` den Elementnamen samt Präfix (`r:Relationship`),
/// und ein Paket mit einem anderen — aber völlig gültigen — Präfix rutscht an
/// jeder Namensprüfung vorbei. Mit ihr ist `elementName` der lokale Name.
///
/// Attributnamen behalten ihr Präfix auch dann. Damit ein Delegate es auflösen
/// kann, meldet `shouldReportNamespacePrefixes` zusätzlich jede
/// Präfix-Deklaration; ohne dieses Flag ruft `XMLParser` die zugehörigen
/// Delegate-Methoden gar nicht erst auf. In die Attributliste geraten die
/// `xmlns`-Deklarationen dadurch nicht.
private func parseXML(_ xml: Data, with delegate: XMLParserDelegate) throws {
    let parser = XMLParser(data: xml)
    parser.delegate = delegate
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = true
    parser.shouldResolveExternalEntities = false
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

private enum ExternalImageRelationshipParser {
    static func targets(in xml: Data) throws -> [String] {
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
    static func packageKind(in xml: Data) throws -> WordProcessingPackageKind {
        let delegate = ContentTypesDelegate()
        try parseXML(xml, with: delegate)
        guard delegate.hasValidRoot else {
            throw ContentTypeError("[Content_Types].xml has no valid Types root")
        }
        guard delegate.mainContentTypes.count == 1,
              let contentType = delegate.mainContentTypes.first else {
            throw ContentTypeError(
                "[Content_Types].xml must declare exactly one content type for word/document.xml"
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
                "word/document.xml has an unsupported main content type: \(contentType)"
            )
        }
    }

    private final class ContentTypesDelegate: NSObject, XMLParserDelegate {
        var hasValidRoot = false
        var mainContentTypes = Set<String>()
        private var sawRoot = false

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
                    == "/word/document.xml",
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
            case "ins", "del", "moveFrom", "moveTo":
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

