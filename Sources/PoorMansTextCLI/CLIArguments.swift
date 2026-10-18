import Foundation
import PoorMansTextCore

struct ParsedArguments {
    var inputURLs = [URL]()
    var outputURL: URL?
    var pandocURL: URL?
    var pdfOptions = ConversionOptions()
    var setsPDFOptions = false
    var json = false
    var progress = false
    var timeout: TimeInterval?
    var jobs = 1
    var setsJobs = false
    var showHelp = false
    var showVersion = false
    var listFormats = false
    var listChapters = false
    var epubChapters: IndexSelection?
    var listSlides = false
    var presentationSelection: PresentationSelection?
    var listSheets = false
    var sheetSelection: SpreadsheetSheetSelection = .all
    var cellRanges: [SpreadsheetCellRange] = []
    var setsSheetSelection = false
    var setsSpreadsheetSelection: Bool { setsSheetSelection || !cellRanges.isEmpty }
    var spreadsheetRendering: SpreadsheetRendering = .markdownTable
    var imageTextRecognition: ImageTextRecognition = .enabled
    var writeToStandardOutput = false
    var frontmatter = false
    var sourceMapping = false
    var conversionReport = false
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

Convert documents, spreadsheets, presentations, notebooks, PDFs, or images into new Markdown folders.

Options:
  -o, --output DIRECTORY  Set the new output directory.
      --pandoc PATH       Use a specific Pandoc executable.
      --formats           List the supported input formats instead of converting.
      --spreadsheet-format table|tsv
                          Render spreadsheets as a GFM table (default) or escaped TSV.
      --sheets all|visible|RANGES  Select source sheet indices, e.g. 1,3-5.
      --sheet-name NAME   Select an exact sheet name (repeatable; excludes --sheets).
      --cell-range A1:B8  Select a cell rectangle on each selected sheet (repeatable).
      --list-sheets       Inspect sheet names, indices and visibility without output folders.
      --slides RANGES    Select source slides, e.g. 1,3-5 (PPTX/PPTM/POTX/ODP).
      --notes on|off     Include presentation notes (default: on).
      --list-slides      Inspect ordered slide titles and local notes references.
      --epub-chapters RANGES  Select EPUB spine entries, e.g. 1,3-5.
      --list-chapters     Inspect EPUB reading order and navigation without conversion.
      --image-ocr on|off  Add local OCR text for images (default) or preserve only the image asset.
      --pdf-ocr auto|always|off  Choose local PDF OCR (default: auto).
      --pdf-pages RANGES  Select source pages, e.g. 1,3-5 (PDF inputs only).
      --ocr-method standard|structured  Local OCR method (structured: macOS 26+, with fallback).
      --ocr-language CODES Comma-separated local OCR languages, e.g. de,en.
      --pdf-layout auto|legacy  Reconstruct PDF structure or keep the previous extraction.
      --pdf-remove-headers-footers  Remove repeated text at page margins.
      --pdf-dehyphenate    Join conservative lowercase word breaks.
      --frontmatter       Start the Markdown with a YAML header (title, author, dates) from the source.
      --textbundle        Write INPUT.textbundle (text.md, assets/, info.json) instead of INPUT-markdown.
      --source-map        Include verified source-to-Markdown byte ranges (requires --json or --report).
      --report            Save conversion-report.json with source/output hashes, options and source mappings.
      --stdout            Print the Markdown to standard output instead of writing a folder.
      --progress          Report phases and known page/sheet/slide/cell progress on stderr.
      --jobs 1..4         Convert up to four batch documents concurrently (default: 1); OCR stays serial.
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
turn by default; --jobs 2 through 4 runs documents concurrently. Failures do not stop the others. A folder is searched recursively
for supported file extensions; packages such as .rtfd count as one document,
and hidden entries, symbolic links, and earlier *-markdown results are skipped.
--output then names a parent directory that receives one INPUT-markdown folder
per document, mirroring the folder structure. Results retain input order, and
the first input reserves a colliding target. OCR runs one image at a time.
--json reports a list under
"results", and the exit code is that of the first failed input. Text mode prints
one result path per line; a path that itself contains a line break spans two
lines, so scripts that parse the output should use --json.

--frontmatter reads title, author, subject, keywords, and dates from OOXML
core properties, OpenDocument meta.xml, the RTF info group, the PDF
information dictionary, the OPF of an EPUB, the title-info of a FictionBook,
or the HTML head; a source without any of them gets a warning instead of
an empty header. --stdout converts exactly one document into a temporary place,
prints its Markdown, and removes that place again; image assets are not kept and
are reported on standard error. It cannot be combined with --json, --output,
--textbundle, --jobs, several inputs, or a folder.

--formats reports every format this build can read, its file extensions, whether
it is a single file or a folder package, which external tools it needs, and
whether those tools are installed right now. It never inspects a document, and
a valid call always exits 0 — even when no format is currently available.
Combining --formats with an input document, an output directory, or a
conversion option such as --spreadsheet-format or --image-ocr is a usage error
and exits 64.
"""

/// Optionen, die einen Wert erwarten — als nächstes Argument oder, bei langen
/// Optionen, als `--name=Wert`. Die Liste ist die einzige Stelle, die das
/// weiß: Parser und Vorabscan lesen sie beide, sonst könnten sie `--pandoc
/// --json` verschieden deuten.
let valueOptions: Set<String> = [
    "-o", "--output", "--pandoc", "--timeout", "--jobs", "--spreadsheet-format",
    "--image-ocr", "--ocr-method", "--pdf-ocr", "--pdf-layout", "--ocr-language", "--pdf-pages", "--sheets", "--sheet-name", "--cell-range", "--slides", "--notes", "--epub-chapters",
]

/// Sagt VOR dem Parsen, ob `--json` als Option vorkommt, damit auch ein
/// Argumentfehler vor `--json` als JSON gemeldet wird. Vorher galt nur das
/// bereits gelesene `--json`; ein Wrapper, der es anhängt, bekam bei einem
/// Fehler Text (Roadmap-Punkt, 2026-09-10). Der Scan ist wertbewusst: Nach
/// einer Option mit Wert wird das nächste Argument übersprungen, sodass
/// `--pandoc --json` ein Werkzeugpfad bleibt; nach `--` sind alle Argumente
/// Eingaben.
func requestsJSONOutput(_ rawArguments: [String]) -> Bool {
    var index = 0
    while index < rawArguments.count {
        let argument = rawArguments[index]
        if argument == "--" { return false }
        if argument == "--json" { return true }
        if valueOptions.contains(argument) { index += 1 }
        index += 1
    }
    return false
}

func parseArguments(
    _ rawArguments: [String],
    into parsed: inout ParsedArguments
) throws {
    var index = 0
    var optionsEnded = false

    while index < rawArguments.count {
        let argument = rawArguments[index]
        index += 1

        if optionsEnded || !argument.hasPrefix("-") {
            parsed.inputURLs.append(try fileURL(argument, option: "an input"))
            continue
        }
        if argument == "--" {
            optionsEnded = true
            continue
        }

        // `--name=Wert` nur bei langen Optionen trennen; `-o=x` bleibt eine
        // unbekannte Option, wie bisher.
        var name = argument
        var inlineValue: String?
        if argument.hasPrefix("--"), let separator = argument.firstIndex(of: "=") {
            name = String(argument[..<separator])
            inlineValue = String(argument[argument.index(after: separator)...])
        }

        if valueOptions.contains(name) {
            let value: String
            if let inlineValue {
                value = inlineValue
            } else {
                guard index < rawArguments.count else { throw CLIArgumentError.missingValue(name) }
                value = rawArguments[index]
                index += 1
            }
            try apply(option: name, value: value, to: &parsed)
        } else {
            // Ein Schalter trägt keinen Wert: `--json=1` ist unbekannt.
            guard inlineValue == nil else { throw CLIArgumentError.unknownOption(argument) }
            try apply(flag: name, to: &parsed)
        }
    }
}

private func apply(flag: String, to parsed: inout ParsedArguments) throws {
    switch flag {
    case "-h", "--help": parsed.showHelp = true
    case "-V", "--version": parsed.showVersion = true
    case "--progress": parsed.progress = true
    case "--pdf-remove-headers-footers":
        parsed.setsPDFOptions = true
        parsed.pdfOptions.pdfRemoveHeadersFooters = true
    case "--pdf-dehyphenate":
        parsed.setsPDFOptions = true
        parsed.pdfOptions.pdfDehyphenate = true
    case "--json": parsed.json = true
    case "--formats": parsed.listFormats = true
    case "--list-sheets": parsed.listSheets = true
    case "--list-slides": parsed.listSlides = true
    case "--list-chapters": parsed.listChapters = true
    case "--stdout": parsed.writeToStandardOutput = true
    case "--frontmatter": parsed.frontmatter = true
    case "--textbundle": parsed.outputLayout = .textbundle
    case "--source-map": parsed.sourceMapping = true
    case "--report": parsed.conversionReport = true
    default: throw CLIArgumentError.unknownOption(flag)
    }
}

private func apply(option: String, value: String, to parsed: inout ParsedArguments) throws {
    switch option {
    case "--timeout":
        guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
            throw CLIArgumentError.invalidConversionOption(
                "--timeout requires positive finite seconds"
            )
        }
        parsed.timeout = seconds
    case "--pdf-ocr":
        parsed.setsPDFOptions = true
        guard let mode = PDFTextRecognition(rawValue: value) else { throw CLIArgumentError.invalidConversionOption("--pdf-ocr requires auto, always, or off") }
        parsed.pdfOptions.pdfTextRecognition = mode
    case "--pdf-pages":
        parsed.setsPDFOptions = true
        do { parsed.pdfOptions.pdfPages = try IndexSelection(value) }
        catch { throw CLIArgumentError.invalidConversionOption("--pdf-pages: " + error.localizedDescription) }
    case "--pdf-layout":
        parsed.setsPDFOptions = true
        guard let layout = PDFLayout(rawValue: value) else { throw CLIArgumentError.invalidConversionOption("--pdf-layout requires auto or legacy") }
        parsed.pdfOptions.pdfLayout = layout
    case "--ocr-method":
        guard let method = OCRMethod(rawValue: value) else { throw CLIArgumentError.invalidConversionOption("--ocr-method requires standard or structured") }
        parsed.pdfOptions.ocrMethod = method
        parsed.setsPDFOptions = true
    case "--ocr-language":
        parsed.setsPDFOptions = true
        do { parsed.pdfOptions.ocrLanguages = try OCRLanguageSelection.resolve(value.components(separatedBy: ",")) }
        catch { throw CLIArgumentError.invalidConversionOption(error.localizedDescription) }
    case "--jobs":
        guard let jobs = Int(value), (1...4).contains(jobs) else { throw CLIArgumentError.invalidConversionOption("--jobs requires an integer from 1 through 4") }
        parsed.jobs = jobs
        parsed.setsJobs = true
    case "--epub-chapters":
        do { parsed.epubChapters = try IndexSelection(value) }
        catch { throw CLIArgumentError.invalidConversionOption("--epub-chapters: " + error.localizedDescription) }
    case "--slides":
        do { parsed.presentationSelection = PresentationSelection(slides: try IndexSelection(value), includeNotes: parsed.presentationSelection?.includeNotes ?? true) }
        catch { throw CLIArgumentError.invalidConversionOption("--slides: " + error.localizedDescription) }
    case "--notes":
        guard ["on", "off"].contains(value) else { throw CLIArgumentError.invalidConversionOption("--notes requires on or off") }
        parsed.presentationSelection = PresentationSelection(slides: parsed.presentationSelection?.slides, includeNotes: value == "on")
    case "--sheets":
        guard !parsed.setsSheetSelection else { throw CLIArgumentError.invalidConversionOption("--sheets cannot be repeated or combined with --sheet-name") }
        do {
            parsed.sheetSelection = value == "all" ? .all : value == "visible" ? .visible : .indices(try IndexSelection(value))
        } catch { throw CLIArgumentError.invalidConversionOption("--sheets: " + error.localizedDescription) }
        parsed.setsSheetSelection = true
    case "--sheet-name":
        guard !value.isEmpty, value.utf8.count <= 1_024 else { throw CLIArgumentError.invalidConversionOption("--sheet-name requires 1 through 1024 UTF-8 bytes") }
        if parsed.setsSheetSelection {
            guard case .names(let names) = parsed.sheetSelection else { throw CLIArgumentError.invalidConversionOption("--sheet-name cannot be combined with --sheets") }
            guard names.count < 256 else { throw CLIArgumentError.invalidConversionOption("at most 256 sheet names may be selected") }
            parsed.sheetSelection = .names(names + [value])
        } else { parsed.sheetSelection = .names([value]) }
        parsed.setsSheetSelection = true
    case "--cell-range":
        do {
            guard parsed.cellRanges.count < 64 else { throw CLIArgumentError.invalidConversionOption("at most 64 cell ranges may be selected") }
            parsed.cellRanges.append(try SpreadsheetCellRange(value))
        } catch { throw CLIArgumentError.invalidConversionOption("--cell-range: " + error.localizedDescription) }
    case "--spreadsheet-format":
        parsed.spreadsheetRendering = try spreadsheetRendering(value)
        parsed.setsSpreadsheetRendering = true
    case "--image-ocr":
        parsed.imageTextRecognition = try imageTextRecognition(value)
        parsed.setsImageTextRecognition = true
    case "-o", "--output":
        parsed.outputURL = try fileURL(value, option: "--output")
    case "--pandoc":
        parsed.pandocURL = try fileURL(value, option: "--pandoc")
    default:
        // `valueOptions` und dieser Switch müssen zusammenpassen; ein Test
        // prüft jede Option der Liste einmal durch.
        throw CLIArgumentError.unknownOption(option)
    }
}

/// Ein LEERER Pfad ist kein Pfad.
///
/// `URL(fileURLWithPath: "")` ergibt das Arbeitsverzeichnis. Damit wandelte
/// `poormans-text "$FILE"` mit leerer Variable den gesamten Arbeitsordner
/// rekursiv um, und `--output ""` schrieb kommentarlos dorthin — beides ohne
/// Rückfrage und ohne Fehler (Review-Fund 2026-09-10).
func fileURL(_ path: String, option: String) throws -> URL {
    guard !path.isEmpty else {
        throw CLIArgumentError.invalidConversionOption("\(option) needs a path, but the value is empty")
    }
    return fileURL(path)
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
    case invalidConversionOption(String)
    case missingValue(String)
    case unknownOption(String)
    case formatsTakesNoInput
    case standardOutputConflict(String)
    case invalidSpreadsheetFormat(String)
    case invalidImageOCROption(String)

    var errorDescription: String? {
        switch self {
        case .invalidConversionOption(let reason): reason
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
