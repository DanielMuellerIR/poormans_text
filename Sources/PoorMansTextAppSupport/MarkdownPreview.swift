import Foundation
import Darwin
import CryptoKit
import PoorMansTextCore

/// Liest höchstens 256 KiB plus ein Prüfbyte; die vollständige Datei bleibt
/// beim Öffnen und Kopieren verfügbar. Geteilte UTF-8-Zeichen am Ende entfallen.
public struct MarkdownPreview: Sendable {
    public let id = UUID()
    public let text: String
    public let truncated: Bool
    public let matchesExpectedOutput: Bool?
    public static let byteLimit = 256 * 1024

    public static func read(_ url: URL, limit: Int = byteLimit, expected: ConversionOutputFile? = nil) throws -> Self {
        precondition(limit >= 0 && limit < Int.max)
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        var hash = SHA256()
        var count = 0
        let maximumRead = expected.map { max(limit + 1, min(1_073_741_824, max(0, $0.byteCount)) + 1) } ?? (limit + 1)
        while count < maximumRead {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(262_144, maximumRead - count)), !chunk.isEmpty else { break }
            count += chunk.count
            if expected != nil { hash.update(data: chunk) }
            if data.count < limit + 1 { data.append(chunk.prefix(limit + 1 - data.count)) }
        }
        var prefix = Data(data.prefix(limit))
        // UTF-8 braucht höchstens vier Bytes pro Zeichen. Nur eine am Limit
        // zerschnittene Endsequenz kürzen, nicht ungültige Inhalte verschleiern.
        if data.count > limit {
            for _ in 0..<3 where String(data: prefix, encoding: .utf8) == nil {
                if !prefix.isEmpty { prefix.removeLast() }
            }
        }
        guard let text = String(data: prefix, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let matches = expected.map { $0.byteCount == count && $0.sha256 == hash.finalize().map { String(format: "%02x", $0) }.joined() }
        return Self(text: text, truncated: data.count > limit, matchesExpectedOutput: matches)
    }
}
