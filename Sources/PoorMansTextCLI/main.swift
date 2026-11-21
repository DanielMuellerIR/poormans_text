import Foundation
import Dispatch
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import PoorMansTextCore

private let cancellation = ConversionCancellationToken()
// Dispatch verarbeitet Signale abseits des blockierten Hauptthreads. Im
// Signalhandler selbst laufen keine Swift-Allokationen oder Dateizugriffe.
private let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    let token = cancellation
    source.setEventHandler { @Sendable in token.cancel() }
    source.resume()
    return source
}
private var parsedArguments = ParsedArguments()
private let rawArguments = Array(CommandLine.arguments.dropFirst())
private let isReceiptExtraction = rawArguments.first == "extract"
#if os(Linux)
private let receiptEditorArguments =
    rawArguments.first == "--json" ? rawArguments.dropFirst() : rawArguments[...]
private let isReceiptEditor = receiptEditorArguments.first == "receipt-editor"
#endif

do {
    // Ein gefangenes SIGPIPE lässt write() mit EPIPE zurückkehren.
    // Bei exec beginnt ein Kind wieder mit der Standardbehandlung.
    signal(SIGPIPE) { _ in }
    _ = signalSources
    // Der wertbewusste Vorabscan legt den Ausgabemodus fest, bevor der Parser
    // an einem früheren Argument scheitern kann.
    parsedArguments.json = requestsJSONOutput(rawArguments)
    #if os(Linux)
    // CommandLine.arguments würde ungültige UTF-8-Bytes bereits ersetzen.
    for index in 1..<Int(CommandLine.argc) {
        guard let value = CommandLine.unsafeArgv[index], String(validatingCString: value) != nil else {
            throw CLIArgumentError.invalidConversionOption(
                "Paths and arguments must contain valid UTF-8 bytes.")
        }
    }
    #endif
    if isReceiptExtraction {
        exit(try runReceiptExtraction(rawArguments.dropFirst(), cancellation: cancellation))
    }
    #if os(Linux)
    if isReceiptEditor {
        exit(try runReceiptEditor(receiptEditorArguments.dropFirst(), cancellation: cancellation))
    }
    #endif
    try parseArguments(rawArguments, into: &parsedArguments)

    if parsedArguments.showHelp {
        try writeOutputLine(usage)
        exit(CLIExitCode.success.rawValue)
    }

    if parsedArguments.showVersion {
        try writeOutputLine("\(ProductInfo.name) \(ProductInfo.version)")
        exit(CLIExitCode.success.rawValue)
    }

    if let selection = parsedArguments.sourcePreview {
        let arguments = parsedArguments
        guard arguments.json, arguments.inputURLs.count == 1, arguments.outputURL == nil,
            arguments.profileExplicit.isEmpty, arguments.profileName == nil, arguments.saveProfileName == nil,
            arguments.importProfileURL == nil, arguments.exportProfileURL == nil, !arguments.listProfiles,
            arguments.profileDirectory == nil, arguments.profileSource == nil, !arguments.allowLocalProfile,
            !arguments.clearProfileSelection,
            arguments.epubChapters == nil, arguments.presentationSelection == nil,
            !arguments.listFormats, !arguments.listSheets, !arguments.listSlides, !arguments.listChapters,
            !arguments.setsSpreadsheetSelection, !arguments.setsSpreadsheetRendering,
            !arguments.setsImageTextRecognition,
            !arguments.setsPDFOptions, !arguments.setsDOCXChangeMode, !arguments.setsJobs,
            arguments.pandocURL == nil,
            !arguments.writeToStandardOutput, !arguments.frontmatter, !arguments.sourceMapping,
            !arguments.conversionReport, !arguments.progress, arguments.outputLayout == .markdownFolder
        else {
            throw CLIArgumentError.invalidConversionOption(
                "a source preview requires --json and one source, without output, profile or conversion options"
            )
        }
        let preview = try DocumentConverter().renderSourcePreview(
            arguments.inputURLs[0], selection: selection,
            cancellation: cancellation, processTimeout: arguments.timeout)
        try writeJSON(JSONSourcePreview(preview: preview))
        exit(CLIExitCode.success.rawValue)
    }

    if try prepareProfiles(&parsedArguments, cancellation: cancellation) {
        exit(CLIExitCode.success.rawValue)
    }
    let arguments = parsedArguments

    if arguments.listFormats {
        guard arguments.profileExplicit.subtracting([.pandocExecutable]).isEmpty, arguments.inputURLs.isEmpty,
            arguments.outputURL == nil,
            !arguments.listSheets, !arguments.listSlides, !arguments.listChapters,
            arguments.epubChapters == nil, arguments.presentationSelection == nil,
            !arguments.setsSpreadsheetSelection, !arguments.setsJobs, !arguments.setsPDFOptions,
            !arguments.setsDOCXChangeMode, !arguments.setsSpreadsheetRendering,
            !arguments.setsImageTextRecognition,
            !arguments.writeToStandardOutput, !arguments.frontmatter, !arguments.sourceMapping,
            !arguments.conversionReport,
            arguments.outputLayout == .markdownFolder, !arguments.progress, arguments.timeout == nil
        else {
            throw CLIArgumentError.formatsTakesNoInput
        }
        try writeFormats(formatCatalog(pandocURL: arguments.pandocURL), json: arguments.json)
        exit(CLIExitCode.success.rawValue)
    }

    guard let firstInputURL = arguments.inputURLs.first else {
        throw CLIArgumentError.missingValue("INPUT")
    }
    if arguments.sourceMapping && !arguments.json && !arguments.conversionReport {
        throw CLIArgumentError.invalidConversionOption("--source-map requires --json or --report.")
    }

    if arguments.listSheets || arguments.listSlides || arguments.listChapters {
        guard arguments.profileExplicit.isEmpty,
            [arguments.listSheets, arguments.listSlides, arguments.listChapters].filter({ $0 }).count == 1,
            arguments.epubChapters == nil, arguments.presentationSelection == nil,
            arguments.inputURLs.count == 1, arguments.outputURL == nil, !arguments.writeToStandardOutput,
            !arguments.setsSpreadsheetSelection, !arguments.setsSpreadsheetRendering,
            !arguments.setsImageTextRecognition,
            !arguments.setsPDFOptions, !arguments.setsDOCXChangeMode, !arguments.setsJobs,
            arguments.pandocURL == nil,
            !arguments.frontmatter, !arguments.sourceMapping, !arguments.conversionReport,
            !arguments.progress, arguments.outputLayout == .markdownFolder
        else {
            throw CLIArgumentError.invalidConversionOption(
                "a content overview requires one matching document and cannot be combined with conversion options"
            )
        }
        if arguments.listChapters {
            let summary = try DocumentConverter().inspectEPUBContents(
                arguments.inputURLs[0], cancellation: cancellation, processTimeout: arguments.timeout)
            if arguments.json {
                try writeJSON(summary)
            } else {
                for chapter in summary.chapters {
                    try writeOutputLine(
                        "\(chapter.number)\t\(chapter.isLinear ? "primary" : "auxiliary")\t\(chapter.isReadable ? "XHTML" : "unavailable")\t\(chapter.title ?? chapter.path)"
                    )
                }
                if summary.chaptersTruncated {
                    writeDiagnostic(
                        "Chapter overview limited to the first \(summary.chapters.count) of \(summary.chapterCount) chapters.\n"
                    )
                }
                for warning in summary.diagnostics { writeDiagnostic("Warning: \(warning.message)\n") }
            }
        } else if arguments.listSlides {
            let summary = try DocumentConverter().inspectPresentationContents(
                arguments.inputURLs[0], cancellation: cancellation, processTimeout: arguments.timeout)
            if arguments.json {
                try writeJSON(summary)
            } else {
                for slide in summary.slides {
                    try writeOutputLine(
                        "\(slide.number)\t\(slide.hasNotes ? "notes" : "no notes")\t\(slide.title ?? "")")
                }
                if summary.slidesTruncated {
                    writeDiagnostic(
                        "Slide overview limited to the first \(summary.slides.count) of \(summary.slideCount) slides.\n"
                    )
                }
            }
        } else {
            let summary = try DocumentConverter().inspectSpreadsheetContents(
                arguments.inputURLs[0], cancellation: cancellation, processTimeout: arguments.timeout)
            if arguments.json {
                try writeJSON(summary)
            } else {
                for sheet in summary.sheets {
                    try writeOutputLine(
                        "\(sheet.index)\t\(sheet.visibility.rawValue)\t\(sheet.isReadable ? "worksheet" : "unsupported")\t\(sheet.name)"
                    )
                }
            }
        }
        exit(0)
    }
    let options = try arguments.conversionOptions
    let enumerator = InputEnumerator()

    if arguments.writeToStandardOutput {
        if arguments.sourceMapping || arguments.conversionReport {
            throw CLIArgumentError.standardOutputConflict("cannot be combined with --source-map or --report")
        }
        if arguments.json {
            throw CLIArgumentError.standardOutputConflict("cannot be combined with --json")
        }
        if arguments.outputURL != nil {
            throw CLIArgumentError.standardOutputConflict("cannot be combined with --output")
        }
        if arguments.outputLayout == .textbundle {
            throw CLIArgumentError.standardOutputConflict("cannot be combined with --textbundle")
        }
        // Wie im Katalogmodus: Eine wirkungslose Angabe ist ein Aufruffehler,
        // kein stilles Schlucken.
        if arguments.setsJobs {
            throw CLIArgumentError.standardOutputConflict("cannot be combined with --jobs")
        }
        if arguments.inputURLs.count > 1 || enumerator.isSearchableDirectory(firstInputURL) {
            throw CLIArgumentError.standardOutputConflict(
                "takes exactly one document, not several or a folder")
        }
        try convertToStandardOutput(
            firstInputURL, options: options, arguments: arguments, cancellation: cancellation)
        exit(CLIExitCode.success.rawValue)
    }

    // Genau eine Eingabe, die kein durchsuchbarer Ordner ist, bleibt der
    // bisherige Einzelweg mit unveränderter Antwort — darauf verlässt sich
    // Fastra. Alles andere ist ein Mehrfachlauf mit Listenantwort.
    if arguments.inputURLs.count > 1 || enumerator.isSearchableDirectory(firstInputURL) {
        let inputs = try enumerator.enumerate(arguments.inputURLs, cancellation: cancellation)
        exit(
            try convertBatch(inputs, arguments: arguments, options: options, cancellation: cancellation)
                .rawValue)
    }

    let destination =
        arguments.outputURL.map(ConversionDestination.directory)
        ?? .adjacentToInput
    let result = try DocumentConverter().convert(
        ConversionRequest(
            inputURL: firstInputURL,
            destination: destination,
            options: options, expectedSourceIdentity: arguments.expectedSourceIdentity
        ),
        progress: progressHandler(arguments, input: firstInputURL), cancellation: cancellation,
        processTimeout: arguments.timeout
    )

    if arguments.json {
        try writeJSON(JSONResponse.success(result))
    } else {
        try writeOutputLine(result.outputDirectory.path)
        for warning in result.warnings {
            writeDiagnostic("Warning: \(warning)\n")
        }
    }

    exit(CLIExitCode.success.rawValue)
} catch let error as CLIOutputError {
    writeError(error.localizedDescription)
    exit(CLIExitCode.inputOutput.rawValue)
} catch {
    do {
        #if os(Linux)
        if isReceiptEditor {
            exit(try writeReceiptCLIError(error, cancellation: cancellation))
        }
        #endif
        if isReceiptExtraction {
            exit(try writeReceiptCLIError(error, cancellation: cancellation))
        }
        let message = error.localizedDescription

        // Der Vorabscan kennt den Ausgabemodus auch bei einem Parserfehler.
        if parsedArguments.json {
            try writeJSON(JSONResponse.failure(message))
        } else {
            writeError(message)
            if error is CLIArgumentError {
                writeDiagnostic("\n\(usage)\n")
            }
        }
        exit(exitCode(for: error).rawValue)
    } catch {
        writeError(error.localizedDescription)
        exit(error is CLIOutputError ? CLIExitCode.inputOutput.rawValue : CLIExitCode.software.rawValue)
    }
}
