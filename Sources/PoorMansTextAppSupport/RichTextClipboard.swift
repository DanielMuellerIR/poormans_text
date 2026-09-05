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
    /// Die gelesenen Rohdaten. RTFD hat Vorrang, weil nur diese Form Bilder
    /// und Farben trägt; sonst genügt RTF.
    public struct Source: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case flatRTFD
            case rtf
        }

        public let kind: Kind
        public let data: Data

        public init(kind: Kind, data: Data) {
            self.kind = kind
            self.data = data
        }

        /// Liest RTFD oder RTF vom Pasteboard; `nil`, wenn beides fehlt.
        @MainActor
        public init?(pasteboard: NSPasteboard) {
            if let data = pasteboard.data(forType: .rtfd), !data.isEmpty {
                self.init(kind: .flatRTFD, data: data)
            } else if let data = pasteboard.data(forType: .rtf), !data.isEmpty {
                self.init(kind: .rtf, data: data)
            } else {
                return nil
            }
        }

        /// Name der temporären Quelldatei; er bestimmt die Formaterkennung nur
        /// über den Inhalt, macht aber die Fortschrittsanzeige lesbar.
        public var fileName: String {
            switch kind {
            case .flatRTFD: "Selection.rtfd"
            case .rtf: "Selection.rtf"
            }
        }
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
        try cancellation?.checkCancellation()
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "PoorMansTextClipboard-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let inputURL = workDirectory.appendingPathComponent(source.fileName)
        switch source.kind {
        case .rtf:
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

        let result = try DocumentConverter().convert(
            ConversionRequest(inputURL: inputURL, destination: .temporary, options: options),
            progress: progress, cancellation: cancellation
        )
        defer { try? fileManager.removeItem(at: result.outputDirectory) }

        let markdown = try String(contentsOf: result.markdownFile, encoding: .utf8)
        var warnings = result.warnings
        if !result.assets.isEmpty {
            let count = result.assets.count
            warnings.append(
                count == 1
                    ? "1 image was left out; the clipboard holds text only, so its image link points nowhere."
                    : "\(count) images were left out; the clipboard holds text only, so their image links point nowhere."
            )
        }
        return ClipboardOutcome(markdown: markdown, warnings: warnings)
    }

    public enum ClipboardError: LocalizedError {
        case noRichText
        case unreadableRichText

        public var errorDescription: String? {
            switch self {
            case .noRichText:
                "The selection contains no rich text. Select formatted text in an app that provides RTF."
            case .unreadableRichText:
                "The selected rich text could not be read."
            }
        }
    }
}
