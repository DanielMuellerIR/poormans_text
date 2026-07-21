import Foundation

/// Prüft und installiert den globalen Link auf die im App-Bundle enthaltene CLI.
public enum CLIInstaller {
    public enum Status: Equatable, Sendable {
        case available
        case conflict
        case installed
        case unavailable
    }

    public static let standardTargetURLs = [
        URL(fileURLWithPath: "/opt/homebrew/bin/poormans-text"),
        URL(fileURLWithPath: "/usr/local/bin/poormans-text"),
    ]
    public static let defaultTargetURL = URL(fileURLWithPath: "/usr/local/bin/poormans-text")

    public static func status(
        sourceURL: URL,
        targetURL: URL,
        fileManager: FileManager = .default
    ) -> Status {
        guard fileManager.isExecutableFile(atPath: sourceURL.path) else {
            return .unavailable
        }

        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: targetURL.path) {
            let resolvedDestination = URL(
                fileURLWithPath: destination,
                relativeTo: targetURL.deletingLastPathComponent()
            ).standardizedFileURL
            return resolvedDestination.path == sourceURL.standardizedFileURL.path
                ? .installed
                : .conflict
        }

        return fileManager.fileExists(atPath: targetURL.path) ? .conflict : .available
    }

    public static func install(sourceURL: URL, targetURL: URL) throws {
        try install(
            sourceURL: sourceURL,
            targetURL: targetURL,
            administratorPrivileges: true
        )
    }

    static func install(
        sourceURL: URL,
        targetURL: URL,
        administratorPrivileges: Bool
    ) throws {
        guard status(sourceURL: sourceURL, targetURL: targetURL) == .available else {
            throw InstallError.targetUnavailable
        }

        let script = #"""
        on run argv
            set sourcePath to item 1 of argv
            set targetPath to item 2 of argv
            set targetDirectory to item 3 of argv
            set useAdministratorPrivileges to item 4 of argv
            set quotedSource to quoted form of sourcePath
            set quotedTarget to quoted form of targetPath
            set quotedDirectory to quoted form of targetDirectory
            set shellCommand to "set -eu; " & ¬
                "if [ -e " & quotedTarget & " ] || [ -L " & quotedTarget & " ]; then " & ¬
                "echo 'Das CLI-Ziel ist inzwischen belegt.' >&2; exit 73; fi; " & ¬
                "/bin/mkdir -p " & quotedDirectory & "; " & ¬
                "/bin/ln -s " & quotedSource & " " & quotedTarget
            if useAdministratorPrivileges is "true" then
                do shell script shellCommand with administrator privileges
            else
                do shell script shellCommand
            end if
        end run
        """#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", script,
            "--",
            sourceURL.path,
            targetURL.path,
            targetURL.deletingLastPathComponent().path,
            administratorPrivileges ? "true" : "false",
        ]
        let standardError = Pipe()
        process.standardOutput = Pipe()
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw InstallError.processFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.processFailed(message ?? "unknown error")
        }
        guard status(sourceURL: sourceURL, targetURL: targetURL) == .installed else {
            throw InstallError.verificationFailed
        }
    }

    private enum InstallError: LocalizedError {
        case processFailed(String)
        case targetUnavailable
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .processFailed(let message):
                "The command-line tool could not be installed: \(message)"
            case .targetUnavailable:
                "The command-line target is unavailable or already belongs to another program."
            case .verificationFailed:
                "The command-line tool was installed but could not be verified."
            }
        }
    }
}
