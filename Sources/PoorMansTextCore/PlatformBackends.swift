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
        fileExtensions: ["png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "webp"],
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
/// Der Katalog kennt die Formate weiterhin, bietet aber keinen ungeprüften Import an.
struct UnavailablePlatformAdapter: DocumentConversionAdapter {
    let descriptor: SupportedFormat
    var supportedFormatDescriptors: [SupportedFormat] { [descriptor] }
    func unavailableReason(for format: InputFormat) -> String? {
        if format == .doc {
            return "The Linux DOC backend remains disabled pending macro-safety acceptance."
        }
        return PlatformBackendUnavailable(format.rawValue.uppercased()).localizedDescription
    }
    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection { .noMatch }
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        throw PlatformBackendUnavailable(context.format.rawValue.uppercased())
    }
}

enum LegacyWordAdapter {
    static let textutilPath = "/usr/bin/textutil"
}

enum RTFDInputPreparation {
    static func prepare(from inputURL: URL, outputURL: URL) throws -> URL {
        throw PlatformBackendUnavailable("RTFD")
    }
}
#endif
