import AppKit
import Foundation
import PoorMansTextCore

/// Ergebnis einer Umwandlung von markiertem Rich Text: das Markdown, das in
/// der Zwischenablage landet, und die Hinweise dazu.
public struct ClipboardOutcome: Sendable, Equatable {
    public let markdown: String
    public let warnings: [String]

    public init(markdown: String, warnings: [String]) {
        self.markdown = markdown
        self.warnings = warnings
    }
}

/// Wandelt Rich Text von einer Zwischenablage über den normalen
/// Dokumentweg um. Das Pasteboard wird nur auf dem Main Thread gelesen; die
/// eigentliche Umwandlung arbeitet danach mit reinen Daten und darf deshalb
/// auf einem Hintergrund-Task laufen.
public enum RichTextClipboard {
    /// Ein explizit gelesener Snapshot. RTFD erhält Paketressourcen und hat
    /// deshalb Vorrang vor RTF, danach folgt HTML. Fehler fallen nicht still
    /// auf eine möglicherweise unvollständige Darstellung zurück.
    public struct Source: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case flatRTFD
            case rtf
            case html
        }

        public let kind: Kind
        public let data: Data

        public init(kind: Kind, data: Data) {
            self.kind = kind
            self.data = data
        }

        /// Kompatibler Einstieg des Systemdienstes.
        @MainActor
        public init?(pasteboard: NSPasteboard) {
            guard let source = try? Self.read(from: pasteboard) else { return nil }
            self = source
        }

        @MainActor
        public static func read(from pasteboard: NSPasteboard) throws -> Source {
            let types = pasteboard.types ?? []
            guard !types.isEmpty else { throw ClipboardError.emptyClipboard }
            guard (pasteboard.pasteboardItems?.count ?? 0) <= 1 else { throw ClipboardError.multipleItems }
            for (type, kind) in [(NSPasteboard.PasteboardType.rtfd, Kind.flatRTFD), (.rtf, .rtf), (.html, .html)] {
                if types.contains(type) {
                    guard let data = pasteboard.data(forType: type), !data.isEmpty else { throw ClipboardError.unreadableRichText }
                    guard data.count <= maximumSourceBytes else { throw ClipboardError.tooLarge }
                    return Source(kind: kind, data: data)
                }
            }
            if types.contains(.string) { throw ClipboardError.plainTextOnly }
            throw ClipboardError.noRichText
        }

        /// Lesbarer Name mit der zum Snapshot passenden Dateiendung.
        public var fileName: String {
            switch kind {
            case .flatRTFD: "Selection.rtfd"
            case .rtf: "Selection.rtf"
            case .html: "Selection.html"
            }
        }
    }

    public static let maximumSourceBytes = 64 * 1_024 * 1_024

    /// Hält ausschließlich das temporäre Ergebnis am Leben. Die temporäre
    /// Quelle existiert nach der Konvertierung nicht mehr.
    public final class Draft: Sendable {
        public let source: Source
        public let options: ConversionOptions
        public let result: ConversionResult

        init(source: Source, options: ConversionOptions, result: ConversionResult) {
            precondition(result.outputLifetime == .temporary)
            self.source = source; self.options = options; self.result = result
        }

        func discard() { try? FileManager.default.removeItem(at: result.outputDirectory) }
        deinit { try? FileManager.default.removeItem(at: result.outputDirectory) }
    }

    /// Legt die Auswahl als Datei in einem eigenen temporären Ordner ab, lässt
    /// den Kern sie in ein temporäres Ziel umwandeln und räumt beides wieder
    /// weg. Bilder aus RTFD kommen nicht mit in die Zwischenablage; das wird
    /// als Hinweis gemeldet, statt die Verweise stillschweigend zu behalten.
    public static func convert(
        _ source: Source,
        options: ConversionOptions = ConversionOptions(),
        progress: ConversionProgressHandler? = nil,
        cancellation: ConversionCancellationToken? = nil
    ) throws -> ClipboardOutcome {
        let result = try convertDocument(source, options: options, progress: progress, cancellation: cancellation)
        defer { try? FileManager.default.removeItem(at: result.outputDirectory) }
        return try clipboardOutcome(from: result)
    }

    public static func convertDocument(
        _ source: Source,
        destination: ConversionDestination = .temporary,
        options: ConversionOptions = ConversionOptions(),
        progress: ConversionProgressHandler? = nil,
        cancellation: ConversionCancellationToken? = nil
    ) throws -> ConversionResult {
        try cancellation?.checkCancellation()
        guard source.data.count <= maximumSourceBytes else { throw ClipboardError.tooLarge }
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "PoorMansTextClipboard-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let inputURL = workDirectory.appendingPathComponent(source.fileName)
        switch source.kind {
        case .rtf, .html:
            try source.data.write(to: inputURL)
        case .flatRTFD:
            // Flat-RTFD ist ein serialisiertes Paket. AppKit packt es wieder
            // in die Ordnerform aus, die der RTFD-Adapter erwartet.
            guard let attributed = NSAttributedString(rtfd: source.data, documentAttributes: nil) else {
                throw ClipboardError.unreadableRichText
            }
            let wrapper = attributed.rtfdFileWrapper(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            )
            guard let wrapper else {
                throw ClipboardError.unreadableRichText
            }
            try wrapper.write(to: inputURL, options: [], originalContentsURL: nil)
        }

        return try DocumentConverter().convert(
            ConversionRequest(inputURL: inputURL, destination: destination, options: options),
            progress: progress, cancellation: cancellation
        )
    }

    public static func clipboardOutcome(from result: ConversionResult) throws -> ClipboardOutcome {
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        var warnings = result.warnings
        if !result.assets.isEmpty {
            // Der Hinweis landet direkt im Fenster, deshalb übersetzt: Vorher
            // ging er als englischer Rohtext in die Oberfläche
            // (Roadmap-Punkt, 2026-09-10).
            let count = result.assets.count
            warnings.append(
                count == 1
                    ? NSLocalizedString("1 image was left out; the clipboard holds text only, so its image link points nowhere.", comment: "")
                    : String(format: NSLocalizedString("%d images were left out; the clipboard holds text only, so their image links point nowhere.", comment: ""), count)
            )
        }
        return ClipboardOutcome(markdown: markdown, warnings: warnings)
    }

    public enum ClipboardError: LocalizedError {
        case noRichText
        case unreadableRichText
        case emptyClipboard
        case plainTextOnly
        case multipleItems
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .noRichText:
                "No supported rich text is available. Copy a selection as RTFD, RTF, or HTML."
            case .unreadableRichText:
                "The selected rich text could not be read."
            case .emptyClipboard:
                "The clipboard is empty. Copy formatted text, then choose Paste Rich Text."
            case .plainTextOnly:
                "The clipboard contains plain text only. Copy formatted text as RTFD, RTF, or HTML."
            case .multipleItems:
                "The clipboard contains several items. Copy one formatted selection at a time."
            case .tooLarge:
                "The clipboard content exceeds the 64 MiB limit. Copy a smaller selection."
            }
        }
    }
}
