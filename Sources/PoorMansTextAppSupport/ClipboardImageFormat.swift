import AppKit
import UniformTypeIdentifiers

/// Verlustfreie Darstellungen zuerst; die gewählten Pasteboard-Bytes bleiben
/// unverändert. Ob die Quell-App dafür umkodiert hat, ist nicht rekonstruierbar.
/// NSImage-/Dateipfad-Fallbacks würden Herkunft, Auflösung oder Alpha verändern.
public enum ClipboardImageFormat: String, Sendable, Equatable, CaseIterable {
    case png, tiff, jpeg, heic, gif, bmp, webp

    var pasteboardType: NSPasteboard.PasteboardType {
        let type: UTType
        switch self {
        case .png: type = .png
        case .tiff: type = .tiff
        case .jpeg: type = .jpeg
        case .heic: type = .heic
        case .gif: type = .gif
        case .bmp: type = .bmp
        case .webp: type = .webP
        }
        return .init(type.identifier)
    }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}
