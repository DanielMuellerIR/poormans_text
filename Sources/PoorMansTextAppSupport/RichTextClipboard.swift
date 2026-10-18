import AppKit
import Foundation
import PoorMansTextCore

/// Ergebnis einer Umwandlung von Zwischenablagedaten: das Markdown, das in
/// der Zwischenablage landet, und die Hinweise dazu.
public struct ClipboardOutcome: Sendable, Equatable {
    public let markdown: String
    public let warnings: [String]

    public init(markdown: String, warnings: [String]) {
        self.markdown = markdown
        self.warnings = warnings
    }
}

/// Wandelt Rich Text und kodierte Bilder über den normalen
/// Dokumentweg um. Das Pasteboard wird nur auf dem Main Thread gelesen; die
/// eigentliche Umwandlung arbeitet danach mit reinen Daten und darf deshalb
/// auf einem Hintergrund-Task laufen.
public enum RichTextClipboard {
    /// Ein explizit gelesener Snapshot. RTFD erhält Paketressourcen und hat
    /// deshalb Vorrang vor RTF, danach folgt HTML. Erst danach werden
    /// tatsächlich angebotene kodierte Bilddaten berücksichtigt. Fehler fallen nicht still
    /// auf eine möglicherweise unvollständige Darstellung zurück.
    public struct Source: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case flatRTFD
            case rtf
            case html
            case image(ClipboardImageFormat)
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
            guard let source = try? Self.read(from: pasteboard, includingImages: false) else { return nil }
            self = source
        }

        @MainActor
        public static func read(from pasteboard: NSPasteboard, includingImages: Bool = true) throws -> Source {
            let change = pasteboard.changeCount
            let types = pasteboard.types ?? []
            guard !types.isEmpty else { throw ClipboardError.emptyClipboard }
            let items = pasteboard.pasteboardItems ?? []
            guard items.count <= 1 else { throw ClipboardError.multipleItems }
            for (type, kind) in [(NSPasteboard.PasteboardType.rtfd, Kind.flatRTFD), (.rtf, .rtf), (.html, .html)] {
                if types.contains(type) {
                    guard let data = pasteboard.data(forType: type), !data.isEmpty else { throw ClipboardError.unreadableRichText }
                    guard data.count <= maximumSourceBytes else { throw ClipboardError.tooLarge }
                    guard pasteboard.changeCount == change else { throw ClipboardError.changedDuringRead }
                    return Source(kind: kind, data: data)
                }
            }
            if includingImages {
                // `pasteboard.types` ergänzt z. B. für JPEG ein synthetisches
                // TIFF. Nur die tatsächlich angebotenen Item-Typen verwenden,
                // sonst kodiert AppKit unbemerkt um und Originalbytes gehen verloren.
                let item = items.first
                let imageTypes = item?.types ?? []
                for format in ClipboardImageFormat.allCases where imageTypes.contains(format.pasteboardType) {
                    guard let data = item?.data(forType: format.pasteboardType), !data.isEmpty else { throw ClipboardError.unreadableImage }
                    guard data.count <= maximumSourceBytes else { throw ClipboardError.tooLarge }
                    guard pasteboard.changeCount == change else { throw ClipboardError.changedDuringRead }
                    return Source(kind: .image(format), data: data)
                }
            }
            if types.contains(.string) { throw ClipboardError.plainTextOnly }
            throw includingImages ? ClipboardError.noSupportedContent : ClipboardError.noRichText
        }

        /// Lesbarer Name mit der zum Snapshot passenden Dateiendung.
        public var fileName: String {
            switch kind {
            case .flatRTFD: "Selection.rtfd"
            case .rtf: "Selection.rtf"
            case .html: "Selection.html"
            case .image(let format): "Clipboard Image.\(format.fileExtension)"
            }
        }

        public var isImage: Bool {
            if case .image = kind { return true }
            return false
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
        case .rtf, .html, .image:
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

        let converter = DocumentConverter()
        if source.isImage {
            // Nur Bilddaten erlauben: Ein falscher Pasteboard-Typ darf keine
            // andere Dokumentkonvertierung oder externe Werkzeuge auslösen.
            guard try converter.detectFormat(at: inputURL) == .image else { throw ClipboardError.unreadableImage }
        }
        return try converter.convert(
            ConversionRequest(inputURL: inputURL, destination: destination, options: options),
            progress: progress, cancellation: cancellation
        )
    }

    public static func clipboardOutcome(from result: ConversionResult) throws -> ClipboardOutcome {
        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        var warnings = result.warnings
        if result.format == .image {
            // Der Bildadapter hält OCR hinter dieser Überschrift getrennt.
            // Nur diesen Teil kopieren: Titel, Metadaten und Originalbildlink
            // gehören zum dauerhaft zu sichernden Dokument, nicht zum OCR-Text.
            guard let start = markdown.range(of: "\n\n## OCR text\n\n") else { throw ClipboardError.noRecognizedText }
            let text = String(markdown[start.upperBound...])
            let content = text.replacingOccurrences(of: "_No text could be extracted from this image frame._", with: "")
                .replacingOccurrences(of: "(?m)^### Frame [0-9]+$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw ClipboardError.noRecognizedText }
            warnings.append(NSLocalizedString("The image was omitted. Only recognized text was copied; save Markdown and Assets to keep the image.", comment: ""))
            return ClipboardOutcome(markdown: text, warnings: warnings)
        }
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
        case unreadableImage
        case changedDuringRead
        case noSupportedContent
        case noRecognizedText

        public var errorDescription: String? {
            switch self {
            case .noRichText:
                "No supported rich text is available. Copy a selection as RTFD, RTF, or HTML."
            case .unreadableRichText:
                "The selected rich text could not be read."
            case .emptyClipboard:
                "The clipboard is empty. Copy formatted text or an image, then choose Paste Text or Image."
            case .plainTextOnly:
                "The clipboard contains plain text only. Copy formatted text as RTFD, RTF, or HTML, or copy an image."
            case .multipleItems:
                "The clipboard contains several items. Copy one formatted selection or image at a time."
            case .tooLarge:
                "The clipboard content exceeds the 64 MiB limit. Copy a smaller selection."
            case .unreadableImage:
                "The selected image could not be read. Copy encoded image data such as PNG or TIFF."
            case .changedDuringRead:
                "The clipboard changed while it was being read. Copy the selection again."
            case .noSupportedContent:
                "No supported text or image data is available. Copy formatted text or a PNG, TIFF, JPEG, HEIC, GIF, BMP, or WebP image."
            case .noRecognizedText:
                "No recognized text is available to copy. Enable image OCR before pasting, or save Markdown and Assets to keep the image."
            }
        }
    }
}
