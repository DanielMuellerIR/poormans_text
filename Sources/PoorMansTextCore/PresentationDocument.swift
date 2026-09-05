import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct PresentationSlide {
    var blocks: [PresentationBlock] = []
    var notes: [PresentationBlock] = []
}
indirect enum PresentationBlock {
    case paragraph(String, level: Int?, ordered: Bool)
    case table([[String]])
    case image(String, String)
}

/// Gemeinsame Ausgabe für OOXML und OpenDocument: Dokumentreihenfolge bleibt
/// maßgeblich; keine Zeichen- oder Text-Shapes werden anhand ihrer Position sortiert.
enum PresentationRenderer {
    static func render(_ slide: PresentationSlide, number: Int, maximumBytes: Int = 128 * 1_024 * 1_024) throws -> String {
        var output = ImportTextBuilder(maximumBytes: maximumBytes)
        try output.append("## Slide \(number)\n\n")
        try blocks(slide.blocks, to: &output, quoted: false)
        if !slide.notes.isEmpty {
            try output.append("\n\n### Notes\n\n")
            try blocks(slide.notes, to: &output, quoted: true)
        }
        try output.append("\n\n")
        return output.value
    }
    private static func blocks(_ blocks: [PresentationBlock], to output: inout ImportTextBuilder, quoted: Bool) throws {
        func isList(_ block: PresentationBlock) -> Bool { if case .paragraph(_, .some, _) = block { return true }; return false }
        for (index, block) in blocks.enumerated() {
            try ConversionExecution.check()
            if index > 0 { try output.append(isList(blocks[index - 1]) && isList(block) ? "\n" : "\n\n") }
            if quoted { try output.append("> ") }
            switch block {
            case .paragraph(let text, let level, let ordered):
                let indent = String(repeating: "    ", count: min(max(level ?? 0, 0), 16))
                if level != nil { try output.append(indent + (ordered ? "1. " : "- ")) }
                let literal = MarkdownEscaping.literalBlock(text)
                var first = true
                for line in literal.split(separator: "\n", omittingEmptySubsequences: false) {
                    if !first { try output.append("\n" + (quoted ? "> " : "") + (level == nil ? "" : indent + "   ")) }
                    try output.append(String(line)); first = false
                }
            case .image(let path, let alt):
                try output.append("![\(MarkdownEscaping.inlineLiteral(alt))](\(path))")
            case .table(let rows):
                let width = rows.map(\.count).max() ?? 0
                guard width > 0 else { continue }
                for (rowIndex, row) in rows.enumerated() {
                    try ConversionExecution.check()
                    if rowIndex > 0 { try output.append("\n" + (quoted ? "> " : "")) }
                    try output.append("| ")
                    for column in 0..<width {
                        if column > 0 { try output.append(" | ") }
                        let text = column < row.count ? row[column] : ""
                        try output.append(MarkdownEscaping.inlineLiteral(text).replacingOccurrences(of: "\n", with: "<br>"))
                    }
                    try output.append(" |")
                    if rowIndex == 0 { try output.append("\n" + (quoted ? "> " : "") + "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |") }
                }
            }
        }
    }
}

/// Prüft vor jeder Vergrößerung des Ergebnisstrings, nicht erst nach der
/// Materialisierung einer ganzen expandierten Tabelle.
struct ImportTextBuilder {
    let maximumBytes: Int
    private(set) var bytes = 0
    private(set) var value = ""
    mutating func append(_ text: String) throws {
        guard text.utf8.count <= maximumBytes - bytes else { throw ImportFailure("presentation Markdown exceeds its output budget") }
        bytes += text.utf8.count
        value += text
    }
}

/// Medien werden nur aus bereits geprüften Paketdaten oder Notebook-Base64
/// übernommen. Keine Pfadauflösung zur Quelle und keine Netzwerkanfragen.
final class ImportMediaStore {
    let output: URL
    private(set) var paths: [String] = []
    private var hashes: [String: String] = [:]
    private var total = 0
    init(output: URL) { self.output = output }
    func save(_ data: Data) throws -> String {
        try ConversionExecution.check()
        guard data.count <= 16 * 1_024 * 1_024 else { throw ImportFailure("image exceeds the 16 MiB asset limit") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension else {
            throw ImportFailure("image format is not supported by the local image decoder")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let path = hashes[hash] { return path }
        guard paths.count < 1_024, data.count <= 128 * 1_024 * 1_024 - total else { throw ImportFailure("images exceed the document asset budget") }
        let path = "images/image\(paths.count + 1).\(ext)"
        let url = output.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        total += data.count; hashes[hash] = path; paths.append(path)
        return path
    }
}

struct ImportDiagnostics {
    private(set) var values: [ConversionWarning] = []
    private var omitted = 0
    mutating func add(_ code: String, _ message: String, page: Int? = nil, cell: String? = nil) {
        guard values.count < 256 else { omitted += 1; return }
        values.append(ConversionWarning(code: code, message: message.count > 4_096 ? String(message.prefix(4_096)) + "…" : message, location: page == nil && cell == nil ? nil : ConversionLocation(page: page, cell: cell)))
    }
    var result: [ConversionWarning] {
        values + (omitted == 0 ? [] : [ConversionWarning(code: "diagnostics.limited", message: "\(omitted) further import diagnostics were omitted after the first 256.")])
    }
}
