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
}

private let usage = """
Usage: poormans-text [options] INPUT

Convert an RTF or macOS RTFD document into a new folder containing Markdown and images.

Options:
  -o, --output DIRECTORY  Set the new output directory.
      --pandoc PATH       Use a specific Pandoc executable.
      --json              Write a machine-readable result to stdout.
  -h, --help              Show this help text.
  -V, --version           Show the product version.

The default output directory is INPUT-markdown next to the source. Existing
output directories are never overwritten. Exit codes follow sysexits values:
64 usage, 65 invalid data, 66 missing input, 69 missing dependency,
70 conversion failure, 73 output collision, and 74 file-system failure.
"""

private func parseArguments(_ rawArguments: [String]) throws -> ParsedArguments {
    var parsed = ParsedArguments()
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

    return parsed
}

private func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
}

private enum CLIArgumentError: LocalizedError {
    case missingValue(String)
    case unknownOption(String)
    case tooManyInputs

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            "Missing value for \(option)."
        case .unknownOption(let option):
            "Unknown option: \(option)"
        case .tooManyInputs:
            "Only one RTF or RTFD input can be converted at a time."
        }
    }
}

private func exitCode(for error: Error) -> CLIExitCode {
    guard let conversionError = error as? ConversionError else {
        return error is CLIArgumentError ? .usage : .software
    }

    switch conversionError {
    case .inputDoesNotExist:
        return .noInput
    case .inputIsNotRichText, .invalidRichText, .unsafeImageReference:
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

do {
    let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))

    if arguments.showHelp {
        print(usage)
        exit(CLIExitCode.success.rawValue)
    }

    if arguments.showVersion {
        print("\(ProductInfo.name) \(ProductInfo.version)")
        exit(CLIExitCode.success.rawValue)
    }

    guard let inputURL = arguments.inputURL else {
        throw CLIArgumentError.missingValue("INPUT")
    }

    let result = try RichTextConverter().convert(
        inputURL: inputURL,
        outputDirectory: arguments.outputURL,
        pandocExecutable: arguments.pandocURL
    )

    if arguments.json {
        writeJSON(
            JSONResponse(
                ok: true,
                version: ProductInfo.version,
                input: result.inputURL.path,
                outputDirectory: result.outputDirectory.path,
                markdownFile: result.markdownFile.path,
                assets: result.assets.map(\.path),
                warnings: result.warnings,
                error: nil
            )
        )
    } else {
        print(result.outputDirectory.path)
        for warning in result.warnings {
            FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
        }
    }

    exit(CLIExitCode.success.rawValue)
} catch {
    let message = error.localizedDescription
    let requestedJSON = CommandLine.arguments.dropFirst().contains("--json")

    if requestedJSON {
        writeJSON(
            JSONResponse(
                ok: false,
                version: ProductInfo.version,
                input: nil,
                outputDirectory: nil,
                markdownFile: nil,
                assets: nil,
                warnings: nil,
                error: message
            )
        )
    } else {
        writeError(message)
        if error is CLIArgumentError {
            FileHandle.standardError.write(Data("\n\(usage)\n".utf8))
        }
    }

    exit(exitCode(for: error).rawValue)
}
