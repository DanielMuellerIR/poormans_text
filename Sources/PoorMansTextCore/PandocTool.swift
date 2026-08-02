import Foundation

enum PandocTool {
    static func resolve(
        _ requestedURL: URL?,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let requestedURL {
            let standardizedURL = requestedURL.standardizedFileURL
            guard isRunnableFile(standardizedURL, fileManager: fileManager) else {
                throw ConversionError.pandocNotFound
            }
            return standardizedURL
        }

        var candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/pandoc"),
            URL(fileURLWithPath: "/usr/local/bin/pandoc"),
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("pandoc")
            })
        }

        if let executable = candidates.first(where: {
            isRunnableFile($0, fileManager: fileManager)
        }) {
            return executable
        }
        throw ConversionError.pandocNotFound
    }

    /// `isExecutableFile` prüft unter POSIX nur das Ausführ- beziehungsweise
    /// Durchsuchrecht und hält deshalb auch ein durchsuchbares Verzeichnis wie
    /// `/tmp` für ausführbar. Dann meldet `--formats` das Format als verfügbar,
    /// und erst der Prozessstart scheitert als Softwarefehler.
    ///
    /// Symlinks werden vorher aufgelöst, weil Homebrew `pandoc` genau so verlinkt.
    private static func isRunnableFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.isExecutableFile(atPath: url.path) else {
            return false
        }
        let values = try? url.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }
}
