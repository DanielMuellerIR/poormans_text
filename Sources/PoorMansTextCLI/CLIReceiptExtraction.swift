import Foundation
import PoorMansTextCore

private let receiptUsage = """
    Usage: poormans-text extract --mask FILE [--output-dir DIRECTORY] [--format json] INPUT [INPUT ...]

    Extract receipt fields using a local mask. Results are saved next to each
    input unless --output-dir specifies a destination.
    The JSON summary goes to stdout. Progress and errors go to stderr.

    Exit codes: 0 all inputs succeeded, 1 review required or an input failed,
    2 invalid command, mask, or output directory, 130 cancelled.
    """

private struct ReceiptCLIArguments {
    let maskURL: URL
    let outputDirectory: URL?
    let inputs: [URL]

    init(_ arguments: ArraySlice<String>) throws {
        var maskURL: URL?
        var outputDirectory: URL?
        var inputs: [URL] = []
        var optionsEnded = false
        var specifiedOptions = Set<String>()
        var remaining = arguments

        while let argument = remaining.popFirst() {
            if optionsEnded || !argument.hasPrefix("-") {
                inputs.append(try fileURL(argument, option: "an input"))
                continue
            }
            if argument == "--" {
                optionsEnded = true
                continue
            }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let option = String(parts[0])
            guard ["--mask", "--output-dir", "--format"].contains(option) else {
                throw CLIArgumentError.unknownOption(option)
            }
            guard specifiedOptions.insert(option).inserted else {
                throw CLIArgumentError.invalidConversionOption("\(option) cannot be repeated")
            }
            guard let value = parts.count == 2 ? String(parts[1]) : remaining.popFirst() else {
                throw CLIArgumentError.missingValue(option)
            }
            switch option {
            case "--mask":
                maskURL = try fileURL(value, option: option)
            case "--output-dir":
                outputDirectory = try fileURL(value, option: option)
            default:
                guard value == "json" else {
                    throw CLIArgumentError.invalidConversionOption("--format requires json")
                }
            }
        }
        guard let maskURL else { throw CLIArgumentError.missingValue("--mask") }
        guard !inputs.isEmpty else { throw CLIArgumentError.missingValue("INPUT") }
        self.maskURL = maskURL
        self.outputDirectory = outputDirectory
        self.inputs = inputs
    }
}

private struct ReceiptCLIHelp: Encodable {
    let help: String
}

private struct ReceiptCLIError: Encodable {
    let error: String
    let cancelled: Bool
    let items: [ReceiptBatchItem] = []
}

func runReceiptExtraction(_ arguments: ArraySlice<String>, cancellation: ConversionCancellationToken) throws
    -> Int32
{
    if arguments.count == 1 && (arguments.first == "--help" || arguments.first == "-h") {
        try writeJSON(ReceiptCLIHelp(help: receiptUsage))
        return 0
    }
    try cancellation.checkCancellation()
    let options = try ReceiptCLIArguments(arguments)
    let mask = try ReceiptMask.load(from: options.maskURL)
    let summary = try ReceiptBatch.run(
        inputs: options.inputs,
        mask: mask,
        outputDirectory: options.outputDirectory,
        cancellation: cancellation
    ) { completed, total, item in
        let status: String
        switch item.status {
        case .success: status = "extracted"
        case .reviewRequired: status = "review required"
        case .failed: status = "failed"
        case .cancelled: status = "cancelled"
        }
        let diagnostic = item.diagnostic.map { " — \($0)" } ?? ""
        writeDiagnostic("[\(completed)/\(total)] \(item.source): \(status)\(diagnostic)\n")
    }
    try writeJSON(summary)
    if summary.cancelled { return CLIExitCode.cancelled.rawValue }
    return summary.items.allSatisfy { $0.status == .success } ? 0 : 1
}

func writeReceiptCLIError(_ error: Error, cancellation: ConversionCancellationToken) throws -> Int32 {
    let cancelled = cancellation.isCancelled || exitCode(for: error) == .cancelled
    let message = error.localizedDescription
    writeError(message)
    try writeJSON(ReceiptCLIError(error: message, cancelled: cancelled))
    return cancelled ? CLIExitCode.cancelled.rawValue : 2
}

#if os(Linux)
func runReceiptEditor(_ arguments: ArraySlice<String>, cancellation: ConversionCancellationToken) throws
    -> Int32
{
    guard arguments.count == 2, arguments.first == "--request", let path = arguments.last else {
        throw CLIArgumentError.invalidConversionOption("receipt-editor requires --request FILE")
    }
    let response = try ReceiptEditorProtocol.run(
        requestFile: fileURL(path, option: "--request"),
        cancellation: cancellation)
    try writeOutput(response)
    return 0
}
#endif
