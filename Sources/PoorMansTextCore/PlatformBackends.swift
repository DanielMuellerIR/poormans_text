import Foundation

public struct PlatformBackendUnavailable: LocalizedError, Sendable {
    public let capability: String
    public init(_ capability: String) { self.capability = capability }
    public var errorDescription: String? {
        "The \(capability) backend is not available in this build."
    }
}

enum PlatformFormatDescriptors {
    #if os(Linux)
    static let pdf = SupportedFormat(format: .pdf, fileExtensions: ["pdf"],
        containerKind: .file, requiredTools: [.pythonPoppler, .bubblewrap, .processGuard])
    #else
    static let pdf = SupportedFormat(format: .pdf, fileExtensions: ["pdf"],
        containerKind: .file, requiredTools: [])
    #endif
    #if os(Linux)
    static let image = SupportedFormat(format: .image,
        fileExtensions: ["png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "webp", "heic"],
        containerKind: .file, requiredTools: [.pythonPillow, .bubblewrap, .processGuard])
    #else
    static let image = SupportedFormat(format: .image,
        fileExtensions: ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "webp"],
        containerKind: .file, requiredTools: [])
    #endif
    #if os(Linux)
    static let doc = SupportedFormat(format: .doc, fileExtensions: ["doc"],
        containerKind: .file, requiredTools: [.libreOffice, .pythonUNO, .pandoc, .bubblewrap, .processGuard])
    #else
    static let doc = SupportedFormat(format: .doc, fileExtensions: ["doc"],
        containerKind: .file, requiredTools: [.textutil, .pandoc])
    #endif
}

#if os(Linux)
enum LegacyWordAdapter {
    static let textutilPath = "/usr/bin/textutil"
}

#endif
