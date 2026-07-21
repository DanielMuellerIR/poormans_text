import Foundation

/// Konvertiert ein macOS-RTFD-Paket synchron in Markdown und Bilddateien.
public struct RTFDConverter: Sendable {
    public init() {}

    public func convert(
        inputURL: URL,
        outputDirectory requestedOutputDirectory: URL? = nil,
        pandocExecutable requestedPandocExecutable: URL? = nil
    ) throws -> ConversionResult {
        let fileManager = FileManager.default
        let inputURL = inputURL.standardizedFileURL
        try validateInput(inputURL, fileManager: fileManager)

        let outputDirectory = (
            requestedOutputDirectory ?? Self.defaultOutputDirectory(for: inputURL)
        ).standardizedFileURL
        try validateOutput(outputDirectory, inputURL: inputURL, fileManager: fileManager)

        let pandocExecutable = try resolvePandoc(requestedPandocExecutable, fileManager: fileManager)
        let outputParent = outputDirectory.deletingLastPathComponent()
        let temporaryRoot = outputParent.appendingPathComponent(
            ".poormans-text-\(UUID().uuidString).tmp",
            isDirectory: true
        )
        let workDirectory = temporaryRoot.appendingPathComponent("work", isDirectory: true)
        let stagedResult = temporaryRoot.appendingPathComponent("result", isDirectory: true)

        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagedResult, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let markedRTFD = workDirectory.appendingPathComponent("marked.rtfd", isDirectory: true)
        let textutilInput = try ColoredTextMarker.markedInputURL(
            from: inputURL,
            outputURL: markedRTFD
        )
        let htmlURL = workDirectory.appendingPathComponent("document.html")
        let textutilResult: ProcessResult
        do {
            textutilResult = try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/textutil"),
                arguments: ["-convert", "html", "-output", htmlURL.path, textutilInput.path],
                currentDirectory: workDirectory
            )
        } catch {
            throw ConversionError.textutilFailed(status: -1, message: error.localizedDescription)
        }

        guard textutilResult.status == 0 else {
            throw ConversionError.textutilFailed(
                status: textutilResult.status,
                message: textutilResult.standardError
            )
        }

        let html: String
        do {
            html = try String(contentsOf: htmlURL, encoding: .utf8)
        } catch {
            throw ConversionError.invalidRTFD(inputURL, reason: "textutil produced no readable HTML")
        }

        let imageDirectory = stagedResult.appendingPathComponent("images", isDirectory: true)
        let rewriteResult = try HTMLImageRewriter.rewrite(
            html: html,
            resourceDirectory: workDirectory,
            imageDirectory: imageDirectory,
            fileManager: fileManager
        )
        let normalizedHTML = stagedResult.appendingPathComponent(".conversion.html")

        do {
            try Data(rewriteResult.html.utf8).write(to: normalizedHTML, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        let markdownName = inputURL.deletingPathExtension().lastPathComponent + ".md"
        let stagedMarkdown = stagedResult.appendingPathComponent(markdownName)
        let pandocResult: ProcessResult
        do {
            pandocResult = try ProcessRunner.run(
                executable: pandocExecutable,
                arguments: [
                    "--from=html",
                    "--to=gfm-raw_html",
                    "--wrap=preserve",
                    "--output", stagedMarkdown.path,
                    normalizedHTML.path,
                ],
                currentDirectory: stagedResult
            )
        } catch {
            throw ConversionError.pandocFailed(status: -1, message: error.localizedDescription)
        }

        guard pandocResult.status == 0 else {
            throw ConversionError.pandocFailed(
                status: pandocResult.status,
                message: pandocResult.standardError
            )
        }

        do {
            let markdown = try String(contentsOf: stagedMarkdown, encoding: .utf8)
            let normalizedMarkdown = MarkdownNormalizer.normalize(markdown)
            try Data(normalizedMarkdown.utf8).write(to: stagedMarkdown, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        do {
            try fileManager.removeItem(at: normalizedHTML)
            try fileManager.moveItem(at: stagedResult, to: outputDirectory)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        let finalMarkdown = outputDirectory.appendingPathComponent(markdownName)
        let finalAssets = rewriteResult.assetNames.sorted().map {
            outputDirectory.appendingPathComponent("images").appendingPathComponent($0)
        }
        let warnings = attachmentWarnings(
            inputURL: inputURL,
            referencedResourceNames: rewriteResult.sourceNames,
            fileManager: fileManager
        )

        return ConversionResult(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            markdownFile: finalMarkdown,
            assets: finalAssets,
            warnings: warnings
        )
    }

    public static func defaultOutputDirectory(for inputURL: URL) -> URL {
        inputURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                inputURL.deletingPathExtension().lastPathComponent + "-markdown",
                isDirectory: true
            )
    }

    private func validateInput(_ inputURL: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
            throw ConversionError.inputDoesNotExist(inputURL)
        }
        guard isDirectory.boolValue, inputURL.pathExtension.lowercased() == "rtfd" else {
            throw ConversionError.inputIsNotRTFD(inputURL)
        }

        let rtfURL = inputURL.appendingPathComponent("TXT.rtf")
        var rtfIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rtfURL.path, isDirectory: &rtfIsDirectory),
              !rtfIsDirectory.boolValue else {
            throw ConversionError.invalidRTFD(inputURL, reason: "TXT.rtf is missing")
        }
    }

    private func validateOutput(
        _ outputURL: URL,
        inputURL: URL,
        fileManager: FileManager
    ) throws {
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw ConversionError.outputAlreadyExists(outputURL)
        }

        let resolvedInputPath = inputURL.resolvingSymlinksInPath().path + "/"
        let resolvedOutputPath = outputURL.resolvingSymlinksInPath().path + "/"
        guard !resolvedOutputPath.hasPrefix(resolvedInputPath) else {
            throw ConversionError.outputInsideInput(outputURL)
        }

        let parent = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ConversionError.outputParentDoesNotExist(parent)
        }
    }

    private func resolvePandoc(_ requestedURL: URL?, fileManager: FileManager) throws -> URL {
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

        if let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return executable
        }
        throw ConversionError.pandocNotFound
    }

    private func attachmentWarnings(
        inputURL: URL,
        referencedResourceNames: Set<String>,
        fileManager: FileManager
    ) -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: inputURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { url in
            guard url.lastPathComponent != "TXT.rtf",
                  !referencedResourceNames.contains(url.lastPathComponent) else {
                return nil
            }
            return "Attachment was not represented in the generated Markdown: \(url.lastPathComponent)"
        }.sorted()
    }
}
