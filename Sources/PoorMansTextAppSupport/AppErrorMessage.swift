import Foundation
import PoorMansTextCore

/// Übersetzt die Fehlerkategorie in der App; Werkzeugmeldungen und technische
/// Parserdetails bleiben im Original erhalten, damit sie nachprüfbar bleiben.
enum AppErrorMessage {
    static func describe(_ error: Error, bundle: Bundle = .main) -> String {
        func format(_ key: String, _ values: CVarArg...) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), arguments: values)
        }
        if let error = error as? ConversionError {
            switch error {
            case .cancelled: return format("Conversion cancelled.")
            case .processTimedOut: return format("The conversion tool exceeded its time limit.")
            case .inputDoesNotExist(let url): return format("Input does not exist: %@", url.path)
            case .unsupportedInput(let url): return format("Unsupported input format: %@", url.path)
            case .invalidInput(let url, let kind, let reason): return format("Invalid %@ input at %@: %@", kind.rawValue.uppercased(), url.path, reason)
            case .ambiguousInput(let url, let kinds): return format("Input matches more than one format at %@: %@", url.path, kinds.map(\.rawValue).sorted().joined(separator: ", "))
            case .invalidRichText(let url, let reason): return format("Invalid rich-text document at %@: %@", url.path, reason)
            case .outputAlreadyExists(let url): return format("Output already exists and will not be overwritten: %@", url.path)
            case .outputParentDoesNotExist(let url): return format("The output parent directory does not exist: %@", url.path)
            case .outputInsideInput(let url): return format("The output directory must not be inside the source document: %@", url.path)
            case .invalidOutputName(let url, let reason): return format("Invalid output name %@: %@", url.path, reason)
            case .pandocNotFound: return format("Pandoc was not found. Install Pandoc or pass --pandoc PATH.")
            case .unsafeImageReference(let reference): return format("The generated document contains an unsafe image reference: %@", reference)
            case .textutilFailed(let status, let message): return format("%@ failed with exit status %d: %@", "textutil", status, message)
            case .pandocFailed(let status, let message): return format("%@ failed with exit status %d: %@", "pandoc", status, message)
            case .fileSystemFailure(let message): return format("File-system operation failed: %@", message)
            }
        }
        if let error = error as? InputEnumerationError {
            switch error {
            case .inputDoesNotExist(let url): return format("Input does not exist: %@", url.path)
            case .noSupportedDocuments(let url): return format("The folder contains no supported documents: %@", url.path)
            case .fileSystemFailure(let url, let message): return format("Could not read the folder %@: %@", url.path, message)
            }
        }
        return error.localizedDescription
    }
}
