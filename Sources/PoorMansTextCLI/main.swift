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
    var inputURL: URL?
    var outputURL: URL?
    var pandocURL: URL?
    var json = false
    var showHelp = false
    var showVersion = false
    var listFormats = false
    var spreadsheetRendering: SpreadsheetRendering = .markdownTable
    /// Wurde `--spreadsheet-format` wirklich angegeben? Der Standardwert allein
    /// verrät das nicht, im Katalogmodus ist aber genau die Angabe der Fehler.
    var setsSpreadsheetRendering = false
}

private struct JSONResponse: Encodable {
    let ok: Bool
    let version: String
    let input: String?
    let outputDirectory: String?
    let markdownFile: String?
    let assets: [String]?
    let warnings: [String]?
    let error: String?

    init(
        ok: Bool,
        input: String? = nil,
        outputDirectory: String? = nil,
        markdownFile: String? = nil,
        assets: [String]? = nil,
        warnings: [String]? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        version = ProductInfo.version
        self.input = input
        self.outputDirectory = outputDirectory
        self.markdownFile = markdownFile
        self.assets = assets
        self.warnings = warnings
        self.error = error
    }

    static func success(_ result: ConversionResult) -> JSONResponse {
        JSONResponse(
            ok: true,
            input: canonicalPath(result.inputURL),
            outputDirectory: canonicalPath(result.outputDirectory),
            markdownFile: canonicalPath(result.markdownFile),
            assets: result.assets.map(canonicalPath),
            warnings: result.warnings
        )
    }

    static func failure(_ error: String) -> JSONResponse {
        JSONResponse(ok: false, error: error)
    }
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
Usage: poormans-text [options] INPUT
       poormans-text --formats [--json] [--pandoc PATH]

Convert a supported word-processing document or spreadsheet into a new folder containing Markdown.

Options:
  -o, --output DIRECTORY  Set the new output directory.
      --pandoc PATH       Use a specific Pandoc executable.
      --formats           List the supported input formats instead of converting.
      --spreadsheet-format table|tsv
                          Render spreadsheets as a GFM table (default) or escaped TSV.
      --json              Write a machine-readable result to stdout.
  -h, --help              Show this help text.
  -V, --version           Show the product version.

The default output directory is INPUT-markdown next to the source. Existing
output directories are never overwritten. Exit codes follow sysexits values:
64 usage, 65 invalid data, 66 missing input, 69 missing dependency,
70 conversion failure, 73 output collision, and 74 file-system failure.

--formats reports every format this build can read, its file extensions, whether
it is a single file or a folder package, which external tools it needs, and
whether those tools are installed right now. It never inspects a document, and
a valid call always exits 0 — even when no format is currently available.
Combining --formats with an input document, an output directory, or a
conversion option such as --spreadsheet-format is a usage error and exits 64.
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
        } else if parsed.inputURL == nil {
            parsed.inputURL = fileURL(argument)
        } else {
            throw CLIArgumentError.tooManyInputs
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

private enum CLIArgumentError: LocalizedError {
    case missingValue(String)
    case unknownOption(String)
    case tooManyInputs
    case formatsTakesNoInput
    case invalidSpreadsheetFormat(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            "Missing value for \(option)."
        case .unknownOption(let option):
            "Unknown option: \(option)"
        case .tooManyInputs:
            "Only one input document can be converted at a time."
        case .formatsTakesNoInput:
            // Streng statt tolerant: Sonst bliebe unklar, ob der Aufruf gelistet
            // oder konvertiert hat — und ein Skript würde das erst am Ergebnis merken.
            // Dasselbe gilt für eine Umwandlungsoption: Sie wirkt im Katalogmodus
            // nicht und wäre still ein Tippfehler ohne Folgen.
            """
            --formats lists formats only; it takes no input document, output \
            directory, or conversion option.
            """
        case .invalidSpreadsheetFormat(let value):
            "Unknown spreadsheet format: \(value). Use table or tsv."
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
    case .textutilFailed, .pandocFailed:
        return .software
    case .fileSystemFailure:
        return .inputOutput
    }
}

private func writeJSON(_ response: JSONResponse) {
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
        guard arguments.inputURL == nil, arguments.outputURL == nil,
              !arguments.setsSpreadsheetRendering else {
            throw CLIArgumentError.formatsTakesNoInput
        }
        writeFormats(formatCatalog(pandocURL: arguments.pandocURL), json: arguments.json)
        exit(CLIExitCode.success.rawValue)
    }

    guard let inputURL = arguments.inputURL else {
        throw CLIArgumentError.missingValue("INPUT")
    }

    let destination = arguments.outputURL.map(ConversionDestination.directory)
        ?? .adjacentToInput
    let result = try DocumentConverter().convert(
        ConversionRequest(
            inputURL: inputURL,
            destination: destination,
            options: ConversionOptions(
                pandocExecutable: arguments.pandocURL,
                spreadsheetRendering: arguments.spreadsheetRendering
            )
        )
    )

    if arguments.json {
        writeJSON(.success(result))
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
        writeJSON(.failure(message))
    } else {
        writeError(message)
        if error is CLIArgumentError {
            FileHandle.standardError.write(Data("\n\(usage)\n".utf8))
        }
    }

    exit(exitCode(for: error).rawValue)
}
