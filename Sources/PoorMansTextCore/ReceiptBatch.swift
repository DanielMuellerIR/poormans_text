import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

public enum ReceiptBatchStatus: String, Codable, Sendable {
    case success, reviewRequired, failed, cancelled
}

public struct ReceiptBatchItem: Codable, Sendable {
    public let source: String
    public let output: String?
    public let status: ReceiptBatchStatus
    public let diagnostic: String?
}

public struct ReceiptBatchSummary: Codable, Sendable {
    public let items: [ReceiptBatchItem]
    public let cancelled: Bool
}

public enum ReceiptBatch {
    public static func destination(for source: URL, outputDirectory: URL? = nil) -> URL {
        (outputDirectory ?? source.deletingLastPathComponent())
            .appendingPathComponent(source.lastPathComponent + ".json")
    }

    public static func run(
        inputs: [URL], mask: ReceiptMask, outputDirectory: URL? = nil,
        cancellation: ConversionCancellationToken = ConversionCancellationToken(),
        progress: (@Sendable (Int, Int, ReceiptBatchItem) -> Void)? = nil
    ) throws -> ReceiptBatchSummary {
        try mask.validate()
        #if os(macOS)
        if let outputDirectory {
            var isDirectory: ObjCBool = false
            guard outputDirectory.isFileURL,
                  FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw ReceiptError.invalidOutputDirectory(outputDirectory) }
        }
        let outputs = inputs.map { destination(for: $0, outputDirectory: outputDirectory) }
        let keys = outputs.map(pathKey)
        let targetCounts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
        let inputPaths = Set(inputs.map(pathKey))
        let context = ConversionExecution.Context(cancellation: cancellation, progress: nil, processTimeout: nil)
        let items = ConversionExecution.$current.withValue(context) {
            var items: [ReceiptBatchItem] = []
            for (index, input) in inputs.enumerated() {
                let output = outputs[index]
                let key = keys[index]
                let conflict = (targetCounts[key] ?? 0) > 1 || inputPaths.contains(key)
                let item = process(input, output: output, mask: mask, conflict: conflict)
                items.append(item)
                progress?(index + 1, inputs.count, item)
            }
            return items
        }
        return ReceiptBatchSummary(items: items, cancelled: items.contains { $0.status == .cancelled })
        #else
        throw ReceiptError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
    private static func process(_ input: URL, output: URL, mask: ReceiptMask, conflict: Bool) -> ReceiptBatchItem {
        do {
            try ConversionExecution.check()
            guard !conflict, !ReceiptJSON.destinationExists(output) else { throw ReceiptError.outputConflict(output) }
            let pdf = try ReceiptPDF.open(at: input)
            let document = try ReceiptPDF.read(pdf)
            let result = try ReceiptExtractor.evaluate(mask, in: document, checkCancellation: ConversionExecution.check)
            try result.write(to: output)
            let review = result.fields.filter { $0.status.needsReview }.map(\.name)
            return ReceiptBatchItem(source: input.path, output: output.path,
                                    status: review.isEmpty ? .success : .reviewRequired,
                                    diagnostic: review.isEmpty ? nil : "Review required: " + review.joined(separator: ", "))
        } catch {
            let cancelled = ConversionExecution.isCancelled
            return ReceiptBatchItem(source: input.path, output: nil,
                                    status: cancelled ? .cancelled : .failed, diagnostic: error.localizedDescription)
        }
    }

    private static func pathKey(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let caseSensitive = try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        let name = caseSensitive == true ? url.lastPathComponent : url.lastPathComponent.lowercased()
        return parent.path + "/" + name
    }
    #endif
}

enum ReceiptJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func write(_ data: Data, to url: URL) throws {
        try ConversionExecution.check()
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let staging = parent.appendingPathComponent(".pmt-receipt-" + UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("result")
        try data.write(to: temporary)
        try ConversionExecution.check()
        #if os(macOS)
        // Eine exklusive Umbenennung veröffentlicht die fertige Datei in einem Schritt.
        let status = renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL))
        #else
        let status = link(temporary.path, url.path)
        #endif
        if status != 0 {
            let error = errno
            if error == EEXIST || destinationExists(url) { throw ReceiptError.outputConflict(url) }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
    }

    static func destinationExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
