import Foundation
import PoorMansTextCore

/// Übersetzt die Fehlerkategorie in der App; Werkzeugmeldungen und technische
/// Parserdetails bleiben im Original erhalten, damit sie nachprüfbar bleiben.
///
/// Öffentlich, weil auch die Oberfläche (eigenes Target) ihre Alerts darüber
/// beschriftet: Die Installationsdialoge zeigten vorher `localizedDescription`
/// und damit englischen Text in der deutschen App (Roadmap-Punkt, 2026-09-10).
public enum AppErrorMessage {
    public static func describe(_ error: Error, bundle: Bundle = .main) -> String {
        func format(_ key: String, _ values: CVarArg...) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), arguments: values)
        }
        if let error = error as? RichTextClipboard.ClipboardError {
            switch error {
            case .noRichText: return format("The selection contains no rich text. Select formatted text in an app that provides RTF.")
            case .unreadableRichText: return format("The selected rich text could not be read.")
            }
        }
        if let error = error as? PandocInstaller.InstallError {
            switch error {
            case .processFailed(let message): return format("Homebrew could not install Pandoc: %@", message)
            case .verificationFailed: return format("Homebrew finished, but Pandoc still cannot be found.")
            case .cancelled: return format("The Pandoc installation was cancelled.")
            case .timedOut: return format("Homebrew did not finish installing Pandoc within %d minutes.", Int(PandocInstaller.installationTimeout / 60))
            }
        }
        if let error = error as? CLIInstaller.InstallError {
            switch error {
            case .processFailed(let message): return format("The command-line tool could not be installed: %@", message)
            case .targetUnavailable: return format("The command-line target is unavailable or already belongs to another program.")
            case .verificationFailed: return format("The command-line tool was installed but could not be verified.")
            }
        }
        if let error = error as? OCRLanguageSelection.SelectionError {
            return format("Invalid OCR language selection: %@", error.reason)
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
            case .earlierResult(let url): return format("The folder is the result of an earlier conversion: %@", url.path)
            case .fileSystemFailure(let url, let message): return format("Could not read the folder %@: %@", url.path, message)
            }
        }
        return error.localizedDescription
    }
}
