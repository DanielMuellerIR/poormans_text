import Foundation

/// Fehler, die Aufrufer des Konvertierungskerns gezielt behandeln können.
public enum ConversionError: LocalizedError, Sendable {
    case inputDoesNotExist(URL)
    case inputIsNotRTFD(URL)
    case invalidRTFD(URL, reason: String)
    case outputAlreadyExists(URL)
    case outputParentDoesNotExist(URL)
    case outputInsideInput(URL)
    case pandocNotFound
    case unsafeImageReference(String)
    case textutilFailed(status: Int32, message: String)
    case pandocFailed(status: Int32, message: String)
    case fileSystemFailure(String)

    public var errorDescription: String? {
        switch self {
        case .inputDoesNotExist(let url):
            "Input does not exist: \(url.path)"
        case .inputIsNotRTFD(let url):
            "Input is not an RTFD package: \(url.path)"
        case .invalidRTFD(let url, let reason):
            "Invalid RTFD package at \(url.path): \(reason)"
        case .outputAlreadyExists(let url):
            "Output already exists and will not be overwritten: \(url.path)"
        case .outputParentDoesNotExist(let url):
            "The output parent directory does not exist: \(url.path)"
        case .outputInsideInput(let url):
            "The output directory must not be inside the source RTFD package: \(url.path)"
        case .pandocNotFound:
            "Pandoc was not found. Install Pandoc or pass --pandoc PATH."
        case .unsafeImageReference(let reference):
            "The generated document contains an unsafe image reference: \(reference)"
        case .textutilFailed(let status, let message):
            externalToolMessage(tool: "textutil", status: status, message: message)
        case .pandocFailed(let status, let message):
            externalToolMessage(tool: "pandoc", status: status, message: message)
        case .fileSystemFailure(let message):
            "File-system operation failed: \(message)"
        }
    }

    private func externalToolMessage(tool: String, status: Int32, message: String) -> String {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "\(tool) failed with exit status \(status)."
        }
        return "\(tool) failed with exit status \(status): \(detail)"
    }
}
