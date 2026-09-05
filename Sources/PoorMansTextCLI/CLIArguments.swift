import Foundation
import PoorMansTextCore

struct ParsedArguments {
    var inputURLs = [URL]()
    var outputURL: URL?
    var pandocURL: URL?
    var json = false
    var progress = false
    var timeout: TimeInterval?
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

let usage = """
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
      --progress          Report phases and known page/sheet progress on stderr.
      --timeout SECONDS   Limit each external tool process (positive seconds).
      --json              Write a machine-readable result to stdout.
  -h, --help              Show this help text.
  -V, --version           Show the product version.

The default output directory is INPUT-markdown next to the source. Existing
output directories are never overwritten. Exit codes follow sysexits values:
64 usage, 65 invalid data, 66 missing input, 69 missing dependency,
70 conversion failure, 73 output collision, 74 file-system failure,
124 tool timeout, and 130 cancelled (SIGINT/SIGTERM).

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

func parseArguments(
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
        } else if !optionsEnded && argument == "--progress" {
            parsed.progress = true
        } else if !optionsEnded && (argument == "--timeout" || argument.hasPrefix("--timeout=")) {
            let value: String
            if argument == "--timeout" {
                index += 1
                guard index < rawArguments.count else { throw CLIArgumentError.missingValue(argument) }
                value = rawArguments[index]
            } else { value = String(argument.dropFirst("--timeout=".count)) }
            guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
                throw CLIArgumentError.missingValue("--timeout requires positive finite seconds")
            }
            parsed.timeout = seconds
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

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
}

func spreadsheetRendering(_ value: String) throws -> SpreadsheetRendering {
    switch value {
    case "table": .markdownTable
    case "tsv": .tabSeparated
    default: throw CLIArgumentError.invalidSpreadsheetFormat(value)
    }
}

func imageTextRecognition(_ value: String) throws -> ImageTextRecognition {
    switch value {
    case "on": .enabled
    case "off": .disabled
    default: throw CLIArgumentError.invalidImageOCROption(value)
    }
}

enum CLIArgumentError: LocalizedError {
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
