import Foundation
import PoorMansTextCore

/// Dokumentangaben in der JSON-Antwort; nur vorhandene Felder werden
/// geschrieben, Daten als ISO 8601 in UTC.
struct JSONMetadata: Encodable {
    let title: String?
    let author: String?
    let subject: String?
    let description: String?
    let keywords: [String]?
    let created: String?
    let modified: String?

    init(_ metadata: DocumentMetadata) {
        title = metadata.title
        author = metadata.author
        subject = metadata.subject
        description = metadata.description
        keywords = metadata.keywords.isEmpty ? nil : metadata.keywords
        created = metadata.created.map(DocumentMetadata.iso8601)
        modified = metadata.modified.map(DocumentMetadata.iso8601)
    }
}

struct JSONResponse: Encodable {
    let ok: Bool
    let version: String
    let input: String?
    let outputDirectory: String?
    let markdownFile: String?
    let assets: [String]?
    let warnings: [String]?
    var diagnostics: [ConversionWarning]? = nil
    let metadata: JSONMetadata?
    let error: String?

    init(
        ok: Bool,
        input: String? = nil,
        outputDirectory: String? = nil,
        markdownFile: String? = nil,
        assets: [String]? = nil,
        warnings: [String]? = nil,
        diagnostics: [ConversionWarning]? = nil,
        metadata: JSONMetadata? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        version = ProductInfo.version
        self.input = input
        self.outputDirectory = outputDirectory
        self.markdownFile = markdownFile
        self.assets = assets
        self.warnings = warnings
        self.diagnostics = diagnostics
        self.metadata = metadata
        self.error = error
    }

    static func success(_ result: ConversionResult) -> JSONResponse {
        JSONResponse(
            ok: true,
            input: canonicalPath(result.inputURL),
            outputDirectory: canonicalPath(result.outputDirectory),
            markdownFile: canonicalPath(result.markdownFile),
            assets: result.assets.map(canonicalPath),
            warnings: result.warnings,
            diagnostics: result.diagnostics.contains { $0.location != nil } ? result.diagnostics : nil,
            metadata: JSONMetadata(result.metadata)
        )
    }

    static func failure(_ error: String) -> JSONResponse {
        JSONResponse(ok: false, error: error)
    }
}

/// Ein Eintrag der Listenantwort bei mehreren Eingaben. Erfolg und Fehler
/// tragen beide den Eingabepfad, damit ein Skript die Zeilen zuordnen kann;
/// die Version steht nur einmal im Kopf der Liste.
struct JSONBatchEntry: Encodable {
    let ok: Bool
    let input: String
    let outputDirectory: String?
    let markdownFile: String?
    let assets: [String]?
    let warnings: [String]?
    var diagnostics: [ConversionWarning]? = nil
    let metadata: JSONMetadata?
    let error: String?

    static func success(_ result: ConversionResult) -> JSONBatchEntry {
        JSONBatchEntry(
            ok: true,
            input: canonicalPath(result.inputURL),
            outputDirectory: canonicalPath(result.outputDirectory),
            markdownFile: canonicalPath(result.markdownFile),
            assets: result.assets.map(canonicalPath),
            warnings: result.warnings,
            diagnostics: result.diagnostics.contains { $0.location != nil } ? result.diagnostics : nil,
            metadata: JSONMetadata(result.metadata),
            error: nil
        )
    }

    static func failure(_ inputURL: URL, _ error: String) -> JSONBatchEntry {
        JSONBatchEntry(
            ok: false,
            input: canonicalPath(inputURL),
            outputDirectory: nil,
            markdownFile: nil,
            assets: nil,
            warnings: nil,
            metadata: nil,
            error: error
        )
    }
}

/// Listenantwort für mehrere Eingaben oder einen Ordner. `ok` ist nur wahr,
/// wenn jede Eingabe gelungen ist.
struct JSONBatchResponse: Encodable {
    let ok: Bool
    let version: String
    let results: [JSONBatchEntry]
}

/// Maschinenlesbarer Formatkatalog. Bewusst eine eigene Antwortform: Ein
/// aufrufendes Programm soll den Katalog nicht aus einer Konvertierungsantwort
/// heraussuchen müssen.
struct FormatsJSONResponse: Encodable {
    struct Entry: Encodable {
        let format: String
        let extensions: [String]
        let container: String
        let requires: [String]
        let available: Bool
        let unavailableReason: String?

        enum CodingKeys: String, CodingKey {
            case format, extensions, container, requires, available, unavailableReason
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(format, forKey: .format)
            try container.encode(extensions, forKey: .extensions)
            try container.encode(self.container, forKey: .container)
            try container.encode(requires, forKey: .requires)
            try container.encode(available, forKey: .available)
            if let unavailableReason {
                try container.encode(unavailableReason, forKey: .unavailableReason)
            } else {
                try container.encodeNil(forKey: .unavailableReason)
            }
        }
    }

    let ok: Bool
    let version: String
    let formats: [Entry]
}

func formatCatalog(pandocURL: URL?) -> [FormatAvailability] {
    DocumentConverter().formatCatalog(
        resolver: ExternalToolResolver(pandocExecutable: pandocURL)
    )
}

func writeFormats(_ catalog: [FormatAvailability], json: Bool) {
    if json {
        let response = FormatsJSONResponse(
            ok: true,
            version: ProductInfo.version,
            formats: catalog.map {
                FormatsJSONResponse.Entry(
                    format: $0.format.format.rawValue,
                    extensions: $0.format.fileExtensions,
                    container: $0.format.containerKind.rawValue,
                    requires: $0.format.requiredTools.map(\.rawValue),
                    available: $0.isAvailable,
                    unavailableReason: $0.unavailableReason
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(response) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        return
    }

    // Spaltenbreiten aus dem echten Inhalt, damit die Textausgabe auch mit
    // später hinzukommenden Formaten lesbar bleibt. Die Werkzeugspalte steht
    // hier genauso wie in der JSON-Ausgabe: Ohne sie verschwiege der als
    // selbstbeschreibend zugesagte Katalog etwa, dass DOC sowohl Pandoc als auch
    // `textutil` braucht.
    let rows = catalog.map { entry -> (String, String, String, String, String) in
        (
            entry.format.format.rawValue,
            entry.format.fileExtensions.map { ".\($0)" }.joined(separator: " "),
            entry.format.containerKind.rawValue,
            entry.format.requiredTools.map(\.rawValue).joined(separator: "+"),
            entry.isAvailable ? "available" : "unavailable (\(entry.unavailableReason ?? "unknown"))"
        )
    }
    let formatWidth = rows.map(\.0.count).max() ?? 0
    let extensionWidth = rows.map(\.1.count).max() ?? 0
    let containerWidth = rows.map(\.2.count).max() ?? 0
    let toolWidth = rows.map(\.3.count).max() ?? 0
    for row in rows {
        let line = row.0.padding(toLength: max(formatWidth, row.0.count) + 2, withPad: " ", startingAt: 0)
            + row.1.padding(toLength: max(extensionWidth, row.1.count) + 2, withPad: " ", startingAt: 0)
            + row.2.padding(toLength: max(containerWidth, row.2.count) + 2, withPad: " ", startingAt: 0)
            + row.3.padding(toLength: max(toolWidth, row.3.count) + 2, withPad: " ", startingAt: 0)
            + row.4
        print(line)
    }
}

func writeJSON(_ response: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(response) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

func writeError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

func canonicalPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
}

enum CLIExitCode: Int32 {
    case success = 0
    case cancelled = 130
    case timedOut = 124
    case usage = 64
    case dataError = 65
    case noInput = 66
    case unavailable = 69
    case software = 70
    case cannotCreate = 73
    case inputOutput = 74
}

func exitCode(for error: Error) -> CLIExitCode {
    if let enumerationError = error as? InputEnumerationError {
        switch enumerationError {
        case .inputDoesNotExist, .noSupportedDocuments:
            return .noInput
        case .fileSystemFailure:
            return .inputOutput
        }
    }
    guard let conversionError = error as? ConversionError else {
        return error is CLIArgumentError ? .usage : .software
    }

    switch conversionError {
    case .cancelled: return .cancelled
    case .processTimedOut: return .timedOut
    case .inputDoesNotExist:
        return .noInput
    case .unsupportedInput, .invalidInput, .ambiguousInput,
         .invalidRichText, .unsafeImageReference:
        return .dataError
    case .pandocNotFound:
        return .unavailable
    case .outputAlreadyExists, .outputParentDoesNotExist, .outputInsideInput:
        return .cannotCreate
    case .invalidOutputName:
        return .usage
    case .textutilFailed, .pandocFailed:
        return .software
    case .fileSystemFailure:
        return .inputOutput
    }
}

