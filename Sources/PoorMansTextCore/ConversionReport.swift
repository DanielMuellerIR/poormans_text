import Foundation
import CryptoKit

public struct ConversionSourceIdentity: Codable, Hashable, Sendable {
    public let name: String
    public let sha256: String?
    public let byteCount: Int?
    public let unavailableReason: String?

    /// Ein Hashvergleich belegt die Byteidentität, keine Inhaltsvollständigkeit.
    public func matchesFile(at url: URL) throws -> Bool {
        guard let sha256, let byteCount else { return false }
        let actual = try ConversionFileFingerprint.read(url)
        return actual.sha256 == sha256 && actual.byteCount == byteCount
    }
}

public struct ConversionTextRange: Codable, Hashable, Sendable {
    public let file: String
    public let utf8Offset: Int
    public let utf8Length: Int

    /// Nur mit den anhand des Ausgabemanifests validierten Dateibytes verwenden.
    public func text(in data: Data) -> String? {
        guard utf8Offset >= 0, utf8Length >= 0, utf8Offset <= data.count,
              utf8Length <= data.count - utf8Offset else { return nil }
        let start = data.index(data.startIndex, offsetBy: utf8Offset)
        let end = data.index(start, offsetBy: utf8Length)
        guard (start == data.endIndex || data[start] & 0xC0 != 0x80),
              (end == data.endIndex || data[end] & 0xC0 != 0x80) else { return nil }
        return String(data: data.subdata(in: start..<end), encoding: .utf8)
    }
}

public struct ConversionSourceMapping: Codable, Hashable, Sendable {
    public let source: ConversionLocation
    public let output: ConversionTextRange
}

public struct ConversionOutputFile: Codable, Hashable, Sendable {
    public let path: String
    public let sha256: String
    public let byteCount: Int

    public func matches(_ data: Data) -> Bool {
        data.count == byteCount && ConversionFileFingerprint.digest(data) == sha256
    }
}

public struct ConversionReport: Codable, Sendable {
    public let schemaVersion: Int
    public let converterVersion: String
    public let format: InputFormat
    public let source: ConversionSourceIdentity
    public let options: Options
    public let diagnostics: [ConversionWarning]
    public let diagnosticGroups: [ConversionDiagnosticGroup]
    public let outputs: [ConversionOutputFile]
    public let sourceMappings: [ConversionSourceMapping]
    public let omittedMappingCount: Int

    /// Portabler Optionsstand ohne absolute Werkzeug- oder Privatpfade.
    public struct Options: Codable, Sendable {
        public let customPandoc: Bool
        public let spreadsheetRendering: SpreadsheetRendering
        public let imageTextRecognition: ImageTextRecognition
        public let frontmatter: Bool
        public let outputLayout: OutputLayout
        public let pdfTextRecognition: PDFTextRecognition
        public let ocrLanguages: [String]
        public let pdfLayout: PDFLayout
        public let pdfRemoveHeadersFooters: Bool
        public let pdfDehyphenate: Bool
        public let pdfPages: IndexSelection?
        public let presentationSelection: PresentationSelection?
        public let spreadsheetSelection: SpreadsheetSelection?
        public let sourceMapping: Bool
        public let conversionReport: Bool
        init(_ options: ConversionOptions) {
            customPandoc = options.pandocExecutable != nil
            spreadsheetRendering = options.spreadsheetRendering
            imageTextRecognition = options.imageTextRecognition
            frontmatter = options.frontmatter
            outputLayout = options.outputLayout
            pdfTextRecognition = options.pdfTextRecognition
            ocrLanguages = options.ocrLanguages
            pdfLayout = options.pdfLayout
            pdfRemoveHeadersFooters = options.pdfRemoveHeadersFooters
            pdfDehyphenate = options.pdfDehyphenate
            pdfPages = options.pdfPages
            presentationSelection = options.presentationSelection
            spreadsheetSelection = options.spreadsheetSelection
            sourceMapping = options.includesSourceMappings
            conversionReport = options.conversionReport
        }
    }
}

struct ConversionFileFingerprint {
    let sha256: String
    let byteCount: Int
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func read(_ url: URL) throws -> Self {
        try VerifiedFileStaging.withVerifiedSource(at: url, maximumBytes: 1_073_741_824, describedAs: "the fingerprinted file") { source, _ in
            var hash = SHA256()
            let count = try source.readChunks(maximumBytes: 1_073_741_824, chunkSize: 262_144,
                budgetExceeded: { ImportFailure("the fingerprinted file exceeds its size limit") }) {
                hash.update(bufferPointer: $0); return true
            }
            return Self(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: count)
        }
    }
}

struct ConversionTextEdit {
    let offset: Int
    let length: Int
    let replacementLength: Int
    var end: Int { offset + length }
    var delta: Int { replacementLength - length }
}

/// Pro Auftrag gebunden: Weder parallele Konvertierungen noch verschachtelte
/// ODM-Importe dürfen Quellbelege oder Bereiche miteinander vermischen.
final class ConversionRecording: @unchecked Sendable {
    enum Failure: LocalizedError {
        case conflictingSource
        var errorDescription: String? { "the primary source changed between verified reads" }
    }
    private let lock = NSLock()
    private var primaryPath: String?
    private var fingerprint: ConversionFileFingerprint?
    private var conflictingReads = false
    private var ranges: [(source: ConversionLocation, offset: Int, length: Int)] = []
    private var mappingBytes = 0
    private var omittedMappings = 0
    var omittedMappingCount: Int { lock.withLock { omittedMappings } }

    func activate(at url: URL) { lock.withLock { primaryPath = url.standardizedFileURL.path } }
    func captures(_ url: URL) -> Bool { lock.withLock { primaryPath == url.standardizedFileURL.path } }
    func capture(_ hash: String, count: Int) {
        lock.withLock {
            if let fingerprint, fingerprint.sha256 != hash || fingerprint.byteCount != count { conflictingReads = true }
            fingerprint = ConversionFileFingerprint(sha256: hash, byteCount: count)
        }
    }
    func identity(named name: String) throws -> ConversionSourceIdentity {
        try lock.withLock {
            guard !conflictingReads else { throw Failure.conflictingSource }
            return ConversionSourceIdentity(name: name, sha256: fingerprint?.sha256, byteCount: fingerprint?.byteCount,
                unavailableReason: fingerprint == nil ? "No complete verified byte stream was recorded for the primary source, for example a directory package." : nil)
        }
    }
    func record(_ source: ConversionLocation, offset: Int, length: Int) {
        lock.withLock {
            let bytes = [source.sheet, source.cell, source.message, source.note].compactMap { $0 }.reduce(64) { $0 + $1.utf8.count }
            guard ranges.count < 100_000, bytes <= 8 * 1_048_576 - mappingBytes else { omittedMappings += 1; return }
            mappingBytes += bytes
            ranges.append((source, offset, length))
        }
    }
    func shift(by bytes: Int) {
        lock.withLock { ranges = ranges.map { ($0.source, $0.offset + bytes, $0.length) } }
    }
    func apply(_ edits: [ConversionTextEdit]) {
        guard !edits.isEmpty else { return }
        lock.withLock {
            let edits = edits.sorted { $0.offset < $1.offset }
            var deltas = [0]
            for edit in edits { deltas.append(deltas.last! + edit.delta) }
            func firstIndex(where predicate: (ConversionTextEdit) -> Bool) -> Int {
                var low = 0, high = edits.count
                while low < high {
                    let mid = (low + high) / 2
                    if predicate(edits[mid]) { high = mid } else { low = mid + 1 }
                }
                return low
            }
            ranges = ranges.compactMap { range in
                let end = range.offset + range.length
                let first = firstIndex { $0.end > range.offset }
                let last = firstIndex { $0.offset >= end }
                guard !(first < edits.count && edits[first].offset < range.offset),
                      !(last > first && edits[last - 1].end > end) else { omittedMappings += 1; return nil }
                return (range.source, range.offset + deltas[first], range.length + deltas[last] - deltas[first])
            }
        }
    }
    func mappings(file: String, markdown: Data) throws -> [ConversionSourceMapping] {
        try lock.withLock {
            try ranges.map { range in
                let output = ConversionTextRange(file: file, utf8Offset: range.offset, utf8Length: range.length)
                guard output.text(in: markdown) != nil else { throw ImportFailure("a source mapping exceeds the final Markdown or splits UTF-8") }
                return ConversionSourceMapping(source: range.source, output: output)
            }
        }
    }
}
