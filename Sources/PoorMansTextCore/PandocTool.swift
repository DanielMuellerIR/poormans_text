import Foundation

enum PandocTool {
    static func resolve(
        _ requestedURL: URL?,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let requestedURL {
            let standardizedURL = requestedURL.standardizedFileURL
            guard fileManager.isExecutableFile(atPath: standardizedURL.path) else {
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
            fileManager.isExecutableFile(atPath: $0.path)
        }) {
            return executable
        }
        throw ConversionError.pandocNotFound
    }
}
