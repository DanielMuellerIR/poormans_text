import Foundation
import Dispatch
import Darwin
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

do {
    _ = signalSources
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
              !arguments.setsJobs, !arguments.setsPDFOptions, !arguments.setsSpreadsheetRendering, !arguments.setsImageTextRecognition,
              !arguments.writeToStandardOutput, !arguments.frontmatter,
              arguments.outputLayout == .markdownFolder, !arguments.progress, arguments.timeout == nil else {
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
        outputLayout: arguments.outputLayout,
        pdfTextRecognition: arguments.pdfOptions.pdfTextRecognition,
        ocrLanguages: arguments.pdfOptions.ocrLanguages,
        pdfLayout: arguments.pdfOptions.pdfLayout,
        pdfRemoveHeadersFooters: arguments.pdfOptions.pdfRemoveHeadersFooters,
        pdfDehyphenate: arguments.pdfOptions.pdfDehyphenate
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
        try convertToStandardOutput(firstInputURL, options: options, arguments: arguments, cancellation: cancellation)
        exit(CLIExitCode.success.rawValue)
    }

    // Genau eine Eingabe, die kein durchsuchbarer Ordner ist, bleibt der
    // bisherige Einzelweg mit unveränderter Antwort — darauf verlässt sich
    // Fastra. Alles andere ist ein Mehrfachlauf mit Listenantwort.
    if arguments.inputURLs.count > 1 || enumerator.isSearchableDirectory(firstInputURL) {
        let inputs = try enumerator.enumerate(arguments.inputURLs, cancellation: cancellation)
        exit(convertBatch(inputs, arguments: arguments, options: options, cancellation: cancellation).rawValue)
    }

    let destination = arguments.outputURL.map(ConversionDestination.directory)
        ?? .adjacentToInput
    let result = try DocumentConverter().convert(
        ConversionRequest(
            inputURL: firstInputURL,
            destination: destination,
            options: options
        ),
        progress: progressHandler(arguments, input: firstInputURL), cancellation: cancellation, processTimeout: arguments.timeout
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
