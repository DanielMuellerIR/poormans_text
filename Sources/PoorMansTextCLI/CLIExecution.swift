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

/// Legt den gemeinsamen Elternordner einer Mehrfachumwandlung an. Dieselben
/// Regeln wie beim Einzelziel: Der Elternordner des Ziels muss existieren, und
/// eine vorhandene Datei gleichen Namens wird nie überschrieben. Ein bereits
/// vorhandener Ordner ist erlaubt — die Kollisionsprüfung je Dokument macht
/// anschließend der Kern.
func prepareBatchOutputRoot(_ url: URL) throws {
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
func batchDestination(
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
func convertBatch(
    _ inputs: [EnumeratedInput],
    arguments: ParsedArguments,
    options: ConversionOptions,
    cancellation: ConversionCancellationToken
) -> CLIExitCode {
    if let outputRoot = arguments.outputURL {
        do {
            try cancellation.checkCancellation()
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
            try cancellation.checkCancellation()
            let destination = try batchDestination(
                for: input,
                outputRoot: arguments.outputURL,
                options: options
            )
            let result = try converter.convert(
                ConversionRequest(inputURL: input.url, destination: destination, options: options),
                progress: progressHandler(arguments, input: input.url), cancellation: cancellation, processTimeout: arguments.timeout
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
            if cancellation.isCancelled {
                firstFailure = exitCode(for: error)
                break
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

func progressHandler(_ arguments: ParsedArguments, input: URL) -> ConversionProgressHandler? {
    guard arguments.progress else { return nil }
    return { value in
        let detail = value.unit.map { " \($0.rawValue) \(value.completed ?? 0)/\(value.total ?? 0)" } ?? ""
        FileHandle.standardError.write(Data("Progress: \(input.lastPathComponent): \(value.phase.rawValue)\(detail)\n".utf8))
    }
}

