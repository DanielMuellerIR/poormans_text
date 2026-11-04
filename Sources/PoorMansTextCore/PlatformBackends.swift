import Foundation

public struct PlatformBackendUnavailable: LocalizedError, Sendable {
    public let capability: String
    public init(_ capability: String) { self.capability = capability }
    public var errorDescription: String? {
        "The \(capability) backend is not available in this build."
    }
}

enum PlatformFormatDescriptors {
    static let pdf = SupportedFormat(format: .pdf, fileExtensions: ["pdf"],
        containerKind: .file, requiredTools: [])
    static let image = SupportedFormat(format: .image,
        fileExtensions: ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp", "webp"],
        containerKind: .file, requiredTools: [])
    static let doc = SupportedFormat(format: .doc, fileExtensions: ["doc"],
        containerKind: .file, requiredTools: [.textutil, .pandoc])
}

#if os(Linux)
/// Der Katalog kennt die Formate weiterhin, bietet aber keinen ungeprüften Import an.
struct UnavailablePlatformAdapter: DocumentConversionAdapter {
    let descriptor: SupportedFormat
    var supportedFormatDescriptors: [SupportedFormat] { [descriptor] }
    func unavailableReason(for format: InputFormat) -> String? {
        PlatformBackendUnavailable(format.rawValue.uppercased()).localizedDescription
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
