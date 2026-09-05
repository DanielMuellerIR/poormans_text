import Foundation
import Darwin

/// Liest höchstens 256 KiB plus ein Prüfbyte; die vollständige Datei bleibt
/// beim Öffnen und Kopieren verfügbar. Geteilte UTF-8-Zeichen am Ende entfallen.
public struct MarkdownPreview: Sendable {
    public let text: String
    public let truncated: Bool
    public static let byteLimit = 256 * 1024

    public static func read(_ url: URL, limit: Int = byteLimit) throws -> Self {
        precondition(limit >= 0 && limit < Int.max)
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
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
        return Self(text: text, truncated: data.count > limit)
    }
}
