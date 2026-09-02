import Foundation
import PoorMansTextCore

private enum CLIExitCode: Int32 {
    case success = 0
    case usage = 64
    case dataError = 65
    case noInput = 66
    case unavailable = 69
    case software = 70
    case cannotCreate = 73
    case inputOutput = 74
}

private struct ParsedArguments {
    var inputURLs = [URL]()
    var outputURL: URL?
    var pandocURL: URL?
    var json = false
    var showHelp = false
    var showVersion = false
    var listFormats = false
    var spreadsheetRendering: SpreadsheetRendering = .markdownTable
    var imageTextRecognition: ImageTextRecognition = .enabled
    var writeToStandardOutput = false
    var frontmatter = false
    var outputLayout: OutputLayout = .markdownFolder
    /// Wurde `--spreadsheet-format` wirklich angegeben? Der Standardwert allein
    /// verrät das nicht, im Katalogmodus ist aber genau die Angabe der Fehler.
    var setsSpreadsheetRendering = false
    /// Wie bei Tabellen ist die explizite Angabe im Katalogmodus ein Fehler.
    var setsImageTextRecognition = false
}

/// Dokumentangaben in der JSON-Antwort; nur vorhandene Felder werden
/// geschrieben, Daten als ISO 8601 in UTC.
private struct JSONMetadata: Encodable {
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

private struct JSONResponse: Encodable {
    let ok: Bool
    let version: String
    let input: String?
    let outputDirectory: String?
    let markdownFile: String?
    let assets: [String]?
    let warnings: [String]?
    let metadata: JSONMetadata?
    let error: String?

    init(
        ok: Bool,
        input: String? = nil,
        outputDirectory: String? = nil,
        markdownFile: String? = nil,
        assets: [String]? = nil,
        warnings: [String]? = nil,
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
private struct JSONBatchEntry: Encodable {
    let ok: Bool
    let input: String
    let outputDirectory: String?
    let markdownFile: String?
    let assets: [String]?
    let warnings: [String]?
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
private struct JSONBatchResponse: Encodable {
    let ok: Bool
    let version: String
    let results: [JSONBatchEntry]
}

/// Maschinenlesbarer Formatkatalog. Bewusst eine eigene Antwortform: Ein
/// aufrufendes Programm soll den Katalog nicht aus einer Konvertierungsantwort
/// heraussuchen müssen.
private struct FormatsJSONResponse: Encodable {
    struct Entry: Encodable {
        let format: String
        let extensions: [String]
        let container: String
        let requires: [String]
        let available: Bool
        let unavailableReason: String?

        private enum CodingKeys: String, CodingKey {
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

private let usage = """
Usage: poormans-text [options] INPUT [INPUT ...]
       poormans-text --formats [--json] [--pandoc PATH]

Convert supported documents, spreadsheets, PDFs, or images into new folders containing Markdown.

Options:
  -o, --output DIRECTORY  Set the new output directory.
      --pandoc PATH       Use a specific Pandoc executable.
      --formats           List the supported input formats instead of converting.
      --spreadsheet-format table|tsv
                          Render spreadsheets as a GFM table (default) or escaped TSV.
      --image-ocr on|off  Add local OCR text for images (default) or preserve only the image asset.
      --frontmatter       Start the Markdown with a YAML header (title, author, dates) from the source.
      --textbundle        Write INPUT.textbundle (text.md, assets/, info.json) instead of INPUT-markdown.
      --stdout            Print the Markdown to standard output instead of writing a folder.
      --json              Write a machine-readable result to stdout.
  -h, --help              Show this help text.
  -V, --version           Show the product version.

The default output directory is INPUT-markdown next to the source. Existing
output directories are never overwritten. Exit codes follow sysexits values:
64 usage, 65 invalid data, 66 missing input, 69 missing dependency,
70 conversion failure, 73 output collision, and 74 file-system failure.

With several inputs, or with a folder as input, every document is converted in
turn and a failure does not stop the others. A folder is searched recursively
for supported file extensions; packages such as .rtfd count as one document,
and hidden entries, symbolic links, and earlier *-markdown results are skipped.
--output then names a parent directory that receives one INPUT-markdown folder
per document, mirroring the folder structure. --json reports a list under
"results", and the exit code is that of the first failed input.

--frontmatter reads title, author, subject, keywords, and dates from OOXML
core properties, OpenDocument meta.xml, the RTF info group, or the PDF
information dictionary; a source without any of them gets a warning instead of
an empty header. --stdout converts exactly one document into a temporary place,
prints its Markdown, and removes that place again; image assets are not kept and
are reported on standard error. It cannot be combined with --json, --output,
--textbundle, several inputs, or a folder.

--formats reports every format this build can read, its file extensions, whether
it is a single file or a folder package, which external tools it needs, and
whether those tools are installed right now. It never inspects a document, and
a valid call always exits 0 — even when no format is currently available.
Combining --formats with an input document, an output directory, or a
conversion option such as --spreadsheet-format or --image-ocr is a usage error
and exits 64.
"""

private func parseArguments(
    _ rawArguments: [String],
    into parsed: inout ParsedArguments
) throws {
    var index = 0
    var optionsEnded = false

    while index < rawArguments.count {
        let argument = rawArguments[index]

        if !optionsEnded && argument == "--" {
            optionsEnded = true
            index += 1
            continue
        }

        if !optionsEnded && (argument == "-h" || argument == "--help") {
            parsed.showHelp = true
        } else if !optionsEnded && (argument == "-V" || argument == "--version") {
            parsed.showVersion = true
        } else if !optionsEnded && argument == "--json" {
            parsed.json = true
        } else if !optionsEnded && argument == "--formats" {
            parsed.listFormats = true
        } else if !optionsEnded && argument == "--stdout" {
            parsed.writeToStandardOutput = true
        } else if !optionsEnded && argument == "--frontmatter" {
            parsed.frontmatter = true
        } else if !optionsEnded && argument == "--textbundle" {
            parsed.outputLayout = .textbundle
        } else if !optionsEnded && argument == "--spreadsheet-format" {
            index += 1
            guard index < rawArguments.count else {
                throw CLIArgumentError.missingValue(argument)
            }
            parsed.spreadsheetRendering = try spreadsheetRendering(rawArguments[index])
            parsed.setsSpreadsheetRendering = true
        } else if !optionsEnded && argument.hasPrefix("--spreadsheet-format=") {
            parsed.spreadsheetRendering = try spreadsheetRendering(
                String(argument.dropFirst("--spreadsheet-format=".count))
            )
            parsed.setsSpreadsheetRendering = true
        } else if !optionsEnded && argument == "--image-ocr" {
            index += 1
            guard index < rawArguments.count else {
                throw CLIArgumentError.missingValue(argument)
            }
            parsed.imageTextRecognition = try imageTextRecognition(rawArguments[index])
            parsed.setsImageTextRecognition = true
        } else if !optionsEnded && argument.hasPrefix("--image-ocr=") {
            parsed.imageTextRecognition = try imageTextRecognition(
                String(argument.dropFirst("--image-ocr=".count))
            )
            parsed.setsImageTextRecognition = true
        } else if !optionsEnded && (argument == "-o" || argument == "--output") {
            index += 1
            guard index < rawArguments.count else {
                throw CLIArgumentError.missingValue(argument)
            }
            parsed.outputURL = fileURL(rawArguments[index])
        } else if !optionsEnded && argument.hasPrefix("--output=") {
            parsed.outputURL = fileURL(String(argument.dropFirst("--output=".count)))
        } else if !optionsEnded && argument == "--pandoc" {
            index += 1
            guard index < rawArguments.count else {
                throw CLIArgumentError.missingValue(argument)
            }
            parsed.pandocURL = fileURL(rawArguments[index])
        } else if !optionsEnded && argument.hasPrefix("--pandoc=") {
            parsed.pandocURL = fileURL(String(argument.dropFirst("--pandoc=".count)))
        } else if !optionsEnded && argument.hasPrefix("-") {
            throw CLIArgumentError.unknownOption(argument)
        } else {
            parsed.inputURLs.append(fileURL(argument))
        }

        index += 1
    }

}

private func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
}

private func canonicalPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
}

private func spreadsheetRendering(_ value: String) throws -> SpreadsheetRendering {
    switch value {
    case "table": .markdownTable
    case "tsv": .tabSeparated
    default: throw CLIArgumentError.invalidSpreadsheetFormat(value)
    }
}

private func imageTextRecognition(_ value: String) throws -> ImageTextRecognition {
    switch value {
    case "on": .enabled
    case "off": .disabled
    default: throw CLIArgumentError.invalidImageOCROption(value)
    }
}

private enum CLIArgumentError: LocalizedError {
    case missingValue(String)
    case unknownOption(String)
    case formatsTakesNoInput
    case standardOutputConflict(String)
    case invalidSpreadsheetFormat(String)
    case invalidImageOCROption(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            "Missing value for \(option)."
        case .unknownOption(let option):
            "Unknown option: \(option)"
        case .formatsTakesNoInput:
            // Streng statt tolerant: Sonst bliebe unklar, ob der Aufruf gelistet
            // oder konvertiert hat — und ein Skript würde das erst am Ergebnis merken.
            // Dasselbe gilt für eine Umwandlungsoption: Sie wirkt im Katalogmodus
            // nicht und wäre still ein Tippfehler ohne Folgen.
            """
            --formats lists formats only; it takes no input document, output \
            directory, or conversion option.
            """
        case .standardOutputConflict(let reason):
            "--stdout \(reason)."
        case .invalidSpreadsheetFormat(let value):
            "Unknown spreadsheet format: \(value). Use table or tsv."
        case .invalidImageOCROption(let value):
            "Unknown image OCR option: \(value). Use on or off."
        }
    }
}

/// Baut die Katalogantwort. Ausgelagert, damit Text- und JSON-Ausgabe
/// garantiert denselben Katalog beschreiben.
private func formatCatalog(pandocURL: URL?) -> [FormatAvailability] {
    DocumentConverter().formatCatalog(
        resolver: ExternalToolResolver(pandocExecutable: pandocURL)
    )
}

private func writeFormats(_ catalog: [FormatAvailability], json: Bool) {
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

private func exitCode(for error: Error) -> CLIExitCode {
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

private func writeJSON(_ response: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(response) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}

/// `--stdout`: in ein temporäres Ziel umwandeln, den Text ausgeben, aufräumen.
/// Bilder haben auf der Standardausgabe keinen Platz; ihre Verweise bleiben im
/// Text stehen, und die Zahl der ausgelassenen Dateien geht an stderr.
private func convertToStandardOutput(_ inputURL: URL, options: ConversionOptions) throws {
    let result = try DocumentConverter().convert(
        ConversionRequest(inputURL: inputURL, destination: .temporary, options: options)
    )
    defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
    let markdown: Data
    do {
        markdown = try Data(contentsOf: result.markdownFile)
    } catch {
        throw ConversionError.fileSystemFailure(error.localizedDescription)
    }
    FileHandle.standardOutput.write(markdown)
    for warning in result.warnings {
        FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
    }
    if !result.assets.isEmpty {
        FileHandle.standardError.write(
            Data("Warning: \(result.assets.count) image asset(s) were not written; --stdout emits text only.\n".utf8)
        )
    }
}

/// Legt den gemeinsamen Elternordner einer Mehrfachumwandlung an. Dieselben
/// Regeln wie beim Einzelziel: Der Elternordner des Ziels muss existieren, und
/// eine vorhandene Datei gleichen Namens wird nie überschrieben. Ein bereits
/// vorhandener Ordner ist erlaubt — die Kollisionsprüfung je Dokument macht
/// anschließend der Kern.
private func prepareBatchOutputRoot(_ url: URL) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw ConversionError.outputAlreadyExists(url)
        }
        return
    }
    let parent = url.deletingLastPathComponent()
    guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw ConversionError.outputParentDoesNotExist(url)
    }
    do {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    } catch {
        throw ConversionError.fileSystemFailure(error.localizedDescription)
    }
}

/// Ziel eines einzelnen Dokuments innerhalb einer Mehrfachumwandlung. Ohne
/// `--output` neben der Quelle; sonst unter dem Elternordner, gespiegelt um den
/// Unterordner, aus dem das Dokument beim Durchsuchen stammt.
private func batchDestination(
    for input: EnumeratedInput,
    outputRoot: URL?,
    options: ConversionOptions
) throws -> ConversionDestination {
    guard let outputRoot else {
        return .adjacentToInput
    }
    var parent = outputRoot
    for component in input.relativeDirectory {
        parent.appendPathComponent(component, isDirectory: true)
    }
    if !input.relativeDirectory.isEmpty {
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
    }
    return .directory(
        parent.appendingPathComponent(
            DocumentConverter.outputDirectoryName(for: input.url, layout: options.outputLayout),
            isDirectory: true
        )
    )
}

/// Wandelt mehrere Eingaben nacheinander um. Ein Fehler beendet den Lauf
/// nicht; er wird je Eingabe berichtet, und der Exit-Code ist der des ersten
/// Fehlers.
private func convertBatch(
    _ inputs: [EnumeratedInput],
    arguments: ParsedArguments,
    options: ConversionOptions
) -> CLIExitCode {
    if let outputRoot = arguments.outputURL {
        do {
            try prepareBatchOutputRoot(outputRoot)
        } catch {
            if arguments.json {
                writeJSON(JSONResponse.failure(error.localizedDescription))
            } else {
                writeError(error.localizedDescription)
            }
            return exitCode(for: error)
        }
    }

    var entries = [JSONBatchEntry]()
    var firstFailure: CLIExitCode?
    var failureCount = 0
    let converter = DocumentConverter()
    for input in inputs {
        do {
            let destination = try batchDestination(
                for: input,
                outputRoot: arguments.outputURL,
                options: options
            )
            let result = try converter.convert(
                ConversionRequest(inputURL: input.url, destination: destination, options: options)
            )
            if arguments.json {
                entries.append(.success(result))
            } else {
                print(result.outputDirectory.path)
                for warning in result.warnings {
                    FileHandle.standardError.write(
                        Data("Warning: \(input.url.lastPathComponent): \(warning)\n".utf8)
                    )
                }
            }
        } catch {
            failureCount += 1
            if firstFailure == nil {
                firstFailure = exitCode(for: error)
            }
            if arguments.json {
                entries.append(.failure(input.url, error.localizedDescription))
            } else {
                writeError("\(input.url.path): \(error.localizedDescription)")
            }
        }
    }

    if arguments.json {
        writeJSON(JSONBatchResponse(ok: failureCount == 0, version: ProductInfo.version, results: entries))
    } else if failureCount > 0 {
        writeError("\(failureCount) of \(inputs.count) inputs failed.")
    }
    return firstFailure ?? .success
}

private var parsedArguments = ParsedArguments()

do {
    try parseArguments(Array(CommandLine.arguments.dropFirst()), into: &parsedArguments)
    let arguments = parsedArguments

    if arguments.showHelp {
        print(usage)
        exit(CLIExitCode.success.rawValue)
    }

    if arguments.showVersion {
        print("\(ProductInfo.name) \(ProductInfo.version)")
        exit(CLIExitCode.success.rawValue)
    }

    if arguments.listFormats {
        guard arguments.inputURLs.isEmpty, arguments.outputURL == nil,
              !arguments.setsSpreadsheetRendering, !arguments.setsImageTextRecognition,
              !arguments.writeToStandardOutput, !arguments.frontmatter,
              arguments.outputLayout == .markdownFolder else {
            throw CLIArgumentError.formatsTakesNoInput
        }
        writeFormats(formatCatalog(pandocURL: arguments.pandocURL), json: arguments.json)
        exit(CLIExitCode.success.rawValue)
    }

    guard let firstInputURL = arguments.inputURLs.first else {
        throw CLIArgumentError.missingValue("INPUT")
    }

    let options = ConversionOptions(
        pandocExecutable: arguments.pandocURL,
        spreadsheetRendering: arguments.spreadsheetRendering,
        imageTextRecognition: arguments.imageTextRecognition,
        frontmatter: arguments.frontmatter,
        outputLayout: arguments.outputLayout
    )
    let enumerator = InputEnumerator()

    if arguments.writeToStandardOutput {
        if arguments.json {
            throw CLIArgumentError.standardOutputConflict("cannot be combined with --json")
        }
        if arguments.outputURL != nil {
            throw CLIArgumentError.standardOutputConflict("cannot be combined with --output")
        }
        if arguments.outputLayout == .textbundle {
            throw CLIArgumentError.standardOutputConflict("cannot be combined with --textbundle")
        }
        if arguments.inputURLs.count > 1 || enumerator.isSearchableDirectory(firstInputURL) {
            throw CLIArgumentError.standardOutputConflict("takes exactly one document, not several or a folder")
        }
        try convertToStandardOutput(firstInputURL, options: options)
        exit(CLIExitCode.success.rawValue)
    }

    // Genau eine Eingabe, die kein durchsuchbarer Ordner ist, bleibt der
    // bisherige Einzelweg mit unveränderter Antwort — darauf verlässt sich
    // Fastra. Alles andere ist ein Mehrfachlauf mit Listenantwort.
    if arguments.inputURLs.count > 1 || enumerator.isSearchableDirectory(firstInputURL) {
        let inputs = try enumerator.enumerate(arguments.inputURLs)
        exit(convertBatch(inputs, arguments: arguments, options: options).rawValue)
    }

    let destination = arguments.outputURL.map(ConversionDestination.directory)
        ?? .adjacentToInput
    let result = try DocumentConverter().convert(
        ConversionRequest(
            inputURL: firstInputURL,
            destination: destination,
            options: options
        )
    )

    if arguments.json {
        writeJSON(JSONResponse.success(result))
    } else {
        print(result.outputDirectory.path)
        for warning in result.warnings {
            FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
        }
    }

    exit(CLIExitCode.success.rawValue)
} catch {
    let message = error.localizedDescription

    if parsedArguments.json {
        writeJSON(JSONResponse.failure(message))
    } else {
        writeError(message)
        if error is CLIArgumentError {
            FileHandle.standardError.write(Data("\n\(usage)\n".utf8))
        }
    }

    exit(exitCode(for: error).rawValue)
}
