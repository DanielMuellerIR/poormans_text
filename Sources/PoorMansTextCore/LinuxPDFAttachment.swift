#if os(Linux)
import Foundation

enum LinuxPDFAttachment {
    static func validate(_ data: Data) throws {
        guard data.count <= ENEXResources.maximumResourceBytes, data.starts(with: Data("%PDF-".utf8)) else {
            throw ImportFailure("an ENEX PDF attachment does not match its declared type")
        }
        try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("attachment.pdf")
            try data.write(to: source, options: .withoutOverwriting)
            let result = try LinuxBackendResources.runPython(script: "poppler", arguments: ["validate-attachment", source.path],
                in: directory, readOnlyPaths: [source])
            if result.status == 69 { throw PlatformBackendUnavailable("Python GI Poppler/Cairo PDF attachment validation") }
            if result.status == 74 { throw ConversionError.fileSystemFailure(result.standardError) }
            guard result.status == 0,
                  result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let bytes = result.standardOutput.data(using: .utf8),
                  let response = try? JSONDecoder().decode(Validation.self, from: bytes),
                  response.encrypted ? response.pageCount == nil : (response.pageCount ?? 0) > 0 else {
                throw ImportFailure("an ENEX PDF attachment could not be validated by the local PDF backend")
            }
        }
    }

    private struct Validation: Decodable {
        let encrypted: Bool
        let pageCount: Int?
    }
}
#endif
