import Foundation
import PoorMansTextCore

/// Prüft beim App-Start, ob Pandoc fehlt, und installiert es auf Wunsch über
/// Homebrew. Der Konvertierungskern selbst installiert nie etwas; dieses
/// Angebot ist bewusst Aufgabe der App.
public enum PandocInstaller {
    /// Was die App anbieten kann, wenn Pandoc fehlt.
    public enum Offer: Equatable, Sendable {
        /// Homebrew ist vorhanden: automatische Installation anbieten.
        case homebrewInstall(brewExecutable: URL)
        /// Kein Homebrew: nur die Installationsanleitung anbieten.
        case manualGuidance
    }

    /// Übliche Homebrew-Orte: Apple Silicon zuerst, dann Intel.
    public static let homebrewCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
        URL(fileURLWithPath: "/usr/local/bin/brew"),
    ]

    /// Offizielle Anleitung; deckt sowohl den Pandoc-Installer als auch
    /// Homebrew ab.
    public static let installationHelpURL = URL(string: "https://pandoc.org/installing.html")!

    public static func resolveHomebrew(
        candidates: [URL] = homebrewCandidates,
        fileManager: FileManager = .default
    ) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Entscheidet, ob und was beim Start angeboten wird. `nil` heißt: nichts
    /// anzeigen — Pandoc ist da oder der Nutzer hat dauerhaft abgelehnt.
    public static func offer(
        pandocIsAvailable: Bool,
        installDeclined: Bool,
        brewExecutable: URL?
    ) -> Offer? {
        guard !pandocIsAvailable, !installDeclined else {
            return nil
        }
        if let brewExecutable {
            return .homebrewInstall(brewExecutable: brewExecutable)
        }
        return .manualGuidance
    }

    public static func installPandoc(brewExecutable: URL) throws {
        try installPandoc(brewExecutable: brewExecutable) {
            ExternalToolResolver().isAvailable(.pandoc)
        }
    }

    static func installPandoc(
        brewExecutable: URL,
        verifyInstallation: () -> Bool
    ) throws {
        let result: (status: Int32, standardError: String)
        do {
            result = try CapturedProcess.run(
                executable: brewExecutable,
                arguments: ["install", "pandoc"]
            )
        } catch {
            throw InstallError.processFailed(error.localizedDescription)
        }

        guard result.status == 0 else {
            let message = result.standardError.isEmpty ? "unknown error" : result.standardError
            throw InstallError.processFailed(message)
        }
        guard verifyInstallation() else {
            throw InstallError.verificationFailed
        }
    }

    enum InstallError: LocalizedError {
        case processFailed(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .processFailed(let message):
                "Homebrew could not install Pandoc: \(message)"
            case .verificationFailed:
                "Homebrew finished, but Pandoc still cannot be found."
            }
        }
    }
}
