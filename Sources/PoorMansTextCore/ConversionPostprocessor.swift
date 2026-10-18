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
        fileManager: FileManager,
        recording: ConversionRecording? = nil
    ) throws -> (markdown: String, assets: [String]) {
        let oldMarkdownURL = stagedOutput.appendingPathComponent(markdownRelativePath)
        var markdown: String
        do {
            markdown = try String(contentsOf: oldMarkdownURL, encoding: .utf8)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        var newAssets = [String]()
        var mapping = [String: String]()
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
                mapping[asset] = newPath
                newAssets.append(newPath)
            }
            var edits: [ConversionTextEdit] = []
            markdown = try MarkdownLinkTargetRewriter.replacing(
                in: markdown, mapping: mapping, checking: ConversionExecution.check,
                observing: recording == nil ? nil : { edits.append($0) })
            recording?.apply(edits)
            // Nach dem Verschieben der Assets keine leeren Adapterordner im Bundle lassen.
            for directoryName in ["images", "attachments"] {
                let directory = stagedOutput.appendingPathComponent(directoryName, isDirectory: true)
                if let remaining = try? fileManager.contentsOfDirectory(atPath: directory.path), remaining.isEmpty {
                    try fileManager.removeItem(at: directory)
                }
            }

            try fileManager.removeItem(at: oldMarkdownURL)
            try Data(markdown.utf8).write(
                to: stagedOutput.appendingPathComponent("text.md"),
                options: .atomic
            )
            try writeTextbundleInfo(in: stagedOutput)
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        return ("text.md", newAssets)
    }

    static func writeTextbundleInfo(in stagedOutput: URL) throws {
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
        try infoData.write(to: stagedOutput.appendingPathComponent("info.json"), options: .withoutOverwriting)
    }

    static func portableDiagnostics(_ warnings: [ConversionWarning], paths: [(String, String)]) -> [ConversionWarning] {
        var limitedFields = 0
        func boundedField(_ value: String?) -> String? {
            guard let value else { return nil }
            guard value.utf8.count <= 4096 else { limitedFields += 1; return nil }
            return value
        }
        let result = warnings.map { warning in
            var message = warning.message
            for (path, replacement) in paths.filter({ !$0.0.isEmpty }).sorted(by: { $0.0.count > $1.0.count }) {
                message = message.replacingOccurrences(of: path, with: replacement)
            }
            if message.utf8.count > 16_384 { message = String(message.prefix(4096)) + "…"; limitedFields += 1 }
            let location = warning.location.map { location in
                ConversionLocation(page: location.page, sheet: boundedField(location.sheet), cell: boundedField(location.cell),
                    slide: location.slide, frame: location.frame, paragraph: location.paragraph,
                    message: boundedField(location.message), note: boundedField(location.note))
            }
            return ConversionWarning(code: warning.code, message: message, location: location == ConversionLocation() ? nil : location,
                                     kind: warning.kind, omittedCount: warning.omittedCount)
        }
        return result + (limitedFields == 0 ? [] : [ConversionWarning(code: "report.detailsLimited",
            message: "\(limitedFields) oversized diagnostic fields were shortened or left unknown in the report. Original conversion diagnostics remain available.", kind: .information)])
    }

    static func write(_ report: ConversionReport, in output: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        guard data.count <= 64 * 1_048_576 else { throw ImportFailure("the conversion report exceeds its 64 MiB limit") }
        let name = "conversion-report.json"
        do { try data.write(to: output.appendingPathComponent(name), options: .withoutOverwriting) }
        catch { throw ConversionError.fileSystemFailure(error.localizedDescription) }
        return name
    }

}
