import Foundation

/// Optionale Nachbearbeitung innerhalb des privaten Staging-Bereichs.
enum ConversionPostprocessor {
    /// Schreibt den YAML-Kopf vor den vorhandenen Markdown-Text.
    static func prepend(_ frontmatter: String, to markdownURL: URL) throws {
        do {
            let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
            try Data((frontmatter + markdown).utf8).write(to: markdownURL, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
    }

    /// Baut das Staging-Ergebnis in ein Textbundle um: `text.md`, Assets unter
    /// `assets/` mit umgeschriebenen Links, dazu `info.json`.
    static func applyTextbundleLayout(
        in stagedOutput: URL,
        markdownRelativePath: String,
        assetRelativePaths: [String],
        fileManager: FileManager
    ) throws -> (markdown: String, assets: [String]) {
        let oldMarkdownURL = stagedOutput.appendingPathComponent(markdownRelativePath)
        var markdown: String
        do {
            markdown = try String(contentsOf: oldMarkdownURL, encoding: .utf8)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        var newAssets = [String]()
        let assetsDirectory = stagedOutput.appendingPathComponent("assets", isDirectory: true)
        do {
            if !assetRelativePaths.isEmpty {
                try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            }
            for asset in assetRelativePaths {
                // Die Adapter benennen Assets bereits eindeutig (`image01.png`,
                // `section02-image01.png`), deshalb genügt der Dateiname.
                let name = (asset as NSString).lastPathComponent
                let newPath = "assets/" + name
                try fileManager.moveItem(
                    at: stagedOutput.appendingPathComponent(asset),
                    to: assetsDirectory.appendingPathComponent(name)
                )
                markdown = MarkdownLinkTargetRewriter.replacing(in: markdown, from: asset, to: newPath)
                newAssets.append(newPath)
            }
            // Den leeren `images/`-Ordner nicht im Bundle lassen.
            let imagesDirectory = stagedOutput.appendingPathComponent("images", isDirectory: true)
            if let remaining = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path),
               remaining.isEmpty {
                try fileManager.removeItem(at: imagesDirectory)
            }

            try fileManager.removeItem(at: oldMarkdownURL)
            try Data(markdown.utf8).write(
                to: stagedOutput.appendingPathComponent("text.md"),
                options: .atomic
            )
            let info: [String: Any] = [
                "version": 2,
                "type": "net.daringfireball.markdown",
                "transient": false,
                "creatorIdentifier": "org.poormanstext.PoorMansText",
            ]
            let infoData = try JSONSerialization.data(
                withJSONObject: info,
                options: [.prettyPrinted, .sortedKeys]
            )
            try infoData.write(to: stagedOutput.appendingPathComponent("info.json"), options: .atomic)
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        return ("text.md", newAssets)
    }

}
