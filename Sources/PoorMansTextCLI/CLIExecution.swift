import Foundation
import PoorMansTextCore

/// `--stdout`: in ein temporäres Ziel umwandeln, den Text ausgeben, aufräumen.
/// Bilder haben auf der Standardausgabe keinen Platz; ihre Verweise bleiben im
/// Text stehen, und die Zahl der ausgelassenen Dateien geht an stderr.
func convertToStandardOutput(_ inputURL: URL, options: ConversionOptions, arguments: ParsedArguments, cancellation: ConversionCancellationToken) throws {
    let result = try DocumentConverter().convert(
        ConversionRequest(inputURL: inputURL, destination: .temporary, options: options),
        progress: progressHandler(arguments, input: inputURL), cancellation: cancellation, processTimeout: arguments.timeout
    )
    defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
    try cancellation.checkCancellation()
    let markdown: Data
    do {
        markdown = try Data(contentsOf: result.markdownFile)
    } catch {
        throw ConversionError.fileSystemFailure(error.localizedDescription)
    }
    try cancellation.checkCancellation()
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

/// Die Planung bleibt ohne Dateisystemänderung. Der gemeinsame Core-Batchplan
/// prüft alle Quellen, bevor er Root oder gespiegelte Elternordner anlegt.
func batchDestination(for input: EnumeratedInput, outputRoot: URL?, options: ConversionOptions) -> ConversionDestination {
    guard let outputRoot else { return .adjacentToInput }
    let parent = input.relativeDirectory.reduce(outputRoot) { $0.appendingPathComponent($1, isDirectory: true) }
    return .directory(parent.appendingPathComponent(DocumentConverter.outputDirectoryName(for: input.url, layout: options.outputLayout)))
}

func convertBatch(_ inputs: [EnumeratedInput], arguments: ParsedArguments, options: ConversionOptions, cancellation: ConversionCancellationToken) -> CLIExitCode {
    let requests = inputs.map { ConversionRequest(inputURL: $0.url, destination: batchDestination(for: $0, outputRoot: arguments.outputURL, options: options), options: options) }
    do {
        let handler: BatchConversionProgressHandler?
        if arguments.progress {
            handler = { event in
            let value = event.documentProgress
            let detail = value?.unit.map { " \($0.rawValue) \(value?.completed ?? 0)/\(value?.total ?? 0)" } ?? ""
            CLIProgressOutput.write("Progress: \(event.inputURL.lastPathComponent): \(value?.phase.rawValue ?? "batch")\(detail); files \(event.completed)/\(event.total), running \(event.running.count)\n")
            }
        } else { handler = nil }
        let results = try BatchConverter().convert(requests, jobs: arguments.jobs,
            outputRoots: arguments.outputURL.map { [$0] } ?? [], cancellation: cancellation,
            processTimeout: arguments.timeout, progress: handler)
        var entries: [JSONBatchEntry] = []
        var firstFailure: CLIExitCode?
        var failures = 0
        for item in results {
            switch item.outcome {
            case .success(let result):
                if arguments.json { entries.append(.success(result)) }
                else {
                    print(result.outputDirectory.path)
                    for warning in result.warnings { CLIProgressOutput.write("Warning: \(item.inputURL.lastPathComponent): \(warning)\n") }
                }
            case .failure(let error):
                failures += 1
                if firstFailure == nil { firstFailure = exitCode(for: error) }
                if arguments.json { entries.append(.failure(item.inputURL, error.localizedDescription)) }
                else { writeError("\(item.inputURL.path): \(error.localizedDescription)") }
            }
        }
        if arguments.json { writeJSON(JSONBatchResponse(ok: failures == 0, version: ProductInfo.version, results: entries)) }
        else if failures > 0 { writeError("\(failures) of \(inputs.count) inputs failed.") }
        return cancellation.isCancelled ? .cancelled : firstFailure ?? .success
    } catch {
        if arguments.json { writeJSON(JSONResponse.failure(error.localizedDescription)) }
        else { writeError(error.localizedDescription) }
        return exitCode(for: error)
    }
}

private enum CLIProgressOutput {
    static let lock = NSLock()
    static func write(_ message: String) { lock.withLock { FileHandle.standardError.write(Data(message.utf8)) } }
}

func progressHandler(_ arguments: ParsedArguments, input: URL) -> ConversionProgressHandler? {
    guard arguments.progress else { return nil }
    return { value in
        let detail = value.unit.map { " \($0.rawValue) \(value.completed ?? 0)/\(value.total ?? 0)" } ?? ""
        FileHandle.standardError.write(Data("Progress: \(input.lastPathComponent): \(value.phase.rawValue)\(detail)\n".utf8))
    }
}

