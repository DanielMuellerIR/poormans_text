import Foundation

/// Fehler, die Aufrufer des Konvertierungskerns gezielt behandeln können.
public enum ConversionError: LocalizedError, Sendable {
    case inputDoesNotExist(URL)
    case unsupportedInput(URL)
    case invalidInput(URL, format: InputFormat, reason: String)
    case ambiguousInput(URL, formats: [InputFormat])
    case invalidRichText(URL, reason: String)
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
            return "Input does not exist: \(url.path)"
        case .unsupportedInput(let url):
            return "Unsupported input format: \(url.path)"
        case .invalidInput(let url, let format, let reason):
            return "Invalid \(format.rawValue.uppercased()) input at \(url.path): \(reason)"
        case .ambiguousInput(let url, let formats):
            let names = formats.map(\.rawValue).sorted().joined(separator: ", ")
            return "Input matches more than one format at \(url.path): \(names)"
        case .invalidRichText(let url, let reason):
            return "Invalid rich-text document at \(url.path): \(reason)"
        case .outputAlreadyExists(let url):
            return "Output already exists and will not be overwritten: \(url.path)"
        case .outputParentDoesNotExist(let url):
            return "The output parent directory does not exist: \(url.path)"
        case .outputInsideInput(let url):
            return "The output directory must not be inside the source document: \(url.path)"
        case .pandocNotFound:
            return "Pandoc was not found. Install Pandoc or pass --pandoc PATH."
        case .unsafeImageReference(let reference):
            return "The generated document contains an unsafe image reference: \(reference)"
        case .textutilFailed(let status, let message):
            return externalToolMessage(tool: "textutil", status: status, message: message)
        case .pandocFailed(let status, let message):
            return externalToolMessage(tool: "pandoc", status: status, message: message)
        case .fileSystemFailure(let message):
            return "File-system operation failed: \(message)"
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
