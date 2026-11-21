import Foundation
import PoorMansTextCore

/// `--stdout`: in ein temporäres Ziel umwandeln, den Text ausgeben, aufräumen.
/// Bilder haben auf der Standardausgabe keinen Platz; ihre Verweise bleiben im
/// Text stehen, und die Zahl der ausgelassenen Dateien geht an stderr.
func convertToStandardOutput(
    _ inputURL: URL, options: ConversionOptions, arguments: ParsedArguments,
    cancellation: ConversionCancellationToken
) throws {
    let result = try DocumentConverter().convert(
        ConversionRequest(
            inputURL: inputURL, destination: .temporary, options: options,
            expectedSourceIdentity: arguments.expectedSourceIdentity),
        progress: progressHandler(arguments, input: inputURL), cancellation: cancellation,
        processTimeout: arguments.timeout
    )
    defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
    try writeToStandardOutput(result, cancellation: cancellation)
}

func writeToStandardOutput(_ result: ConversionResult, cancellation: ConversionCancellationToken) throws {
    try cancellation.checkCancellation()
    guard !result.isCollection else {
        throw CLIArgumentError.invalidConversionOption(
            "--stdout cannot represent a document collection. Choose an output folder or Textbundle to retain its documents and links."
        )
    }
    let markdown: Data
    do {
        markdown = try Data(contentsOf: result.markdownFile)
    } catch {
        throw ConversionError.fileSystemFailure(error.localizedDescription)
    }
    try cancellation.checkCancellation()
    try writeOutput(markdown)
    for warning in result.warnings {
        writeDiagnostic("Warning: \(warning)\n")
    }
    if !result.assets.isEmpty {
        writeDiagnostic(
            "Warning: \(result.assets.count) image asset(s) were not written; --stdout emits text only.\n")
    }
}

/// Die Planung bleibt ohne Dateisystemänderung. Der gemeinsame Core-Batchplan
/// prüft alle Quellen, bevor er Root oder gespiegelte Elternordner anlegt.
func batchDestination(for input: EnumeratedInput, outputRoot: URL?, options: ConversionOptions)
    -> ConversionDestination
{
    guard let outputRoot else { return .adjacentToInput }
    let parent = input.relativeDirectory.reduce(outputRoot) {
        $0.appendingPathComponent($1, isDirectory: true)
    }
    return .directory(
        parent.appendingPathComponent(
            DocumentConverter.outputDirectoryName(for: input.url, layout: options.outputLayout)))
}

func convertBatch(
    _ inputs: [EnumeratedInput], arguments: ParsedArguments, options: ConversionOptions,
    cancellation: ConversionCancellationToken
) throws -> CLIExitCode {
    let requests = inputs.map {
        ConversionRequest(
            inputURL: $0.url,
            destination: batchDestination(for: $0, outputRoot: arguments.outputURL, options: options),
            options: options)
    }
    let handler: BatchConversionProgressHandler?
    if arguments.progress {
        let output = BatchProgressOutput()
        handler = { event in
            let value = event.documentProgress
            let detail = conversionProgressDetail(value)
            output.write(
                "Progress: \(event.inputURL.lastPathComponent): \(value?.phase.rawValue ?? "batch")\(detail); "
                    + "files \(event.completed)/\(event.total), running \(event.running.count)\n",
                sequence: event.sequence
            )
        }
    } else {
        handler = nil
    }
    let results = try BatchConverter().convert(
        requests, jobs: arguments.jobs,
        outputRoots: arguments.outputURL.map { [$0] } ?? [], cancellation: cancellation,
        processTimeout: arguments.timeout, progress: handler)
    var entries: [JSONBatchEntry] = []
    var firstFailure: CLIExitCode?
    var failures = 0
    for item in results {
        switch item.outcome {
        case .success(let result):
            if arguments.json {
                entries.append(.success(result))
            } else {
                try writeOutputLine(result.outputDirectory.path)
                for warning in result.warnings {
                    writeDiagnostic("Warning: \(item.inputURL.lastPathComponent): \(warning)\n")
                }
            }
        case .failure(let error):
            failures += 1
            if firstFailure == nil { firstFailure = exitCode(for: error) }
            if arguments.json {
                entries.append(.failure(item.inputURL, error.localizedDescription))
            } else {
                writeError("\(item.inputURL.path): \(error.localizedDescription)")
            }
        }
    }
    if arguments.json {
        try writeJSON(JSONBatchResponse(ok: failures == 0, version: ProductInfo.version, results: entries))
    } else if failures > 0 {
        writeError("\(failures) of \(inputs.count) inputs failed.")
    }
    return cancellation.isCancelled ? .cancelled : firstFailure ?? .success
}

private final class BatchProgressOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSequence = 0

    // Der Batch ruft Fortschrittshandler außerhalb seiner Sperre auf.
    // Reihenfolgeprüfung und Ausgabe müssen daher hier zusammenbleiben.
    func write(_ message: String, sequence: Int) {
        lock.withLock {
            guard sequence > lastSequence else { return }
            lastSequence = sequence
            writeDiagnostic(message)
        }
    }
}

private func conversionProgressDetail(_ value: ConversionProgress?) -> String {
    guard let value, let unit = value.unit, let completed = value.completed else { return "" }
    return " \(unit.rawValue) \(completed)" + (value.total.map { "/\($0)" } ?? "")
}

func progressHandler(_ arguments: ParsedArguments, input: URL) -> ConversionProgressHandler? {
    guard arguments.progress else { return nil }
    return { value in
        let detail = conversionProgressDetail(value)
        writeDiagnostic("Progress: \(input.lastPathComponent): \(value.phase.rawValue)\(detail)\n")
    }
}
