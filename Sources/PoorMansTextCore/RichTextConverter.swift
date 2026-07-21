import Foundation

/// Konvertiert RTF- und macOS-RTFD-Dokumente synchron in Markdown und Bilddateien.
public struct RichTextConverter: Sendable {
    public init() {}

    public func convert(
        inputURL: URL,
        outputDirectory requestedOutputDirectory: URL? = nil,
        pandocExecutable requestedPandocExecutable: URL? = nil
    ) throws -> ConversionResult {
        let fileManager = FileManager.default
        let inputURL = inputURL.standardizedFileURL
        let inputKind = try validateInput(inputURL, fileManager: fileManager)

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

        let htmlURL = workDirectory.appendingPathComponent("document.html")
        let emptyParagraphMarker = inputKind == .rtf
            ? "POORMANSTEXTEMPTY\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            : nil
        try createHTML(
            from: inputURL,
            kind: inputKind,
            at: htmlURL,
            workDirectory: workDirectory,
            pandocExecutable: pandocExecutable,
            emptyParagraphMarker: emptyParagraphMarker
        )

        var html: String
        do {
            html = try String(contentsOf: htmlURL, encoding: .utf8)
        } catch {
            throw ConversionError.invalidRichText(
                inputURL,
                reason: "conversion produced no readable HTML"
            )
        }
        if let emptyParagraphMarker {
            // Pandocs RTF-Reader verwirft leere Absätze. Der Marker wird vor
            // dieser Stufe eingefügt und hier in einen sichtbaren Leerabsatz
            // zurückübersetzt.
            html = html.replacingOccurrences(of: emptyParagraphMarker, with: "<br>")
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
            let normalizedMarkdown = MarkdownNormalizer.normalize(
                markdown,
                joinsAdjacentPlainLines: inputKind == .rtfd
            )
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
        let warnings = warnings(
            inputURL: inputURL,
            kind: inputKind,
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

    private func validateInput(_ inputURL: URL, fileManager: FileManager) throws -> InputKind {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
            throw ConversionError.inputDoesNotExist(inputURL)
        }

        switch inputURL.pathExtension.lowercased() {
        case "rtfd":
            guard isDirectory.boolValue else {
                throw ConversionError.inputIsNotRichText(inputURL)
            }
            let rtfURL = inputURL.appendingPathComponent("TXT.rtf")
            var rtfIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rtfURL.path, isDirectory: &rtfIsDirectory),
                  !rtfIsDirectory.boolValue else {
                throw ConversionError.invalidRichText(inputURL, reason: "TXT.rtf is missing")
            }
            guard try hasRTFHeader(at: rtfURL) else {
                throw ConversionError.invalidRichText(inputURL, reason: "TXT.rtf has no RTF header")
            }
            return .rtfd

        case "rtf":
            guard !isDirectory.boolValue else {
                throw ConversionError.inputIsNotRichText(inputURL)
            }
            guard try hasRTFHeader(at: inputURL) else {
                throw ConversionError.invalidRichText(inputURL, reason: "the RTF header is missing")
            }
            return .rtf

        default:
            throw ConversionError.inputIsNotRichText(inputURL)
        }
    }

    private func hasRTFHeader(at url: URL) throws -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 16) ?? Data()
            return prefix.starts(with: Data(#"{\rtf"#.utf8))
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
    }

    private func createHTML(
        from inputURL: URL,
        kind: InputKind,
        at htmlURL: URL,
        workDirectory: URL,
        pandocExecutable: URL,
        emptyParagraphMarker: String?
    ) throws {
        switch kind {
        case .rtfd:
            let markedRTFD = workDirectory.appendingPathComponent("marked.rtfd", isDirectory: true)
            let textutilInput = try ColoredTextMarker.markedInputURL(
                from: inputURL,
                outputURL: markedRTFD
            )
            let result: ProcessResult
            do {
                result = try ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/textutil"),
                    arguments: ["-convert", "html", "-output", htmlURL.path, textutilInput.path],
                    currentDirectory: workDirectory
                )
            } catch {
                throw ConversionError.textutilFailed(status: -1, message: error.localizedDescription)
            }
            guard result.status == 0 else {
                throw ConversionError.textutilFailed(
                    status: result.status,
                    message: result.standardError
                )
            }

        case .rtf:
            guard let emptyParagraphMarker else {
                throw ConversionError.fileSystemFailure("internal RTF marker is missing")
            }
            let preparedRTF = workDirectory.appendingPathComponent("document.rtf")
            do {
                let source = try Data(contentsOf: inputURL)
                let prepared = preservingEmptyRTFParagraphs(
                    in: source,
                    marker: emptyParagraphMarker
                )
                try prepared.write(to: preparedRTF, options: .atomic)
            } catch {
                throw ConversionError.fileSystemFailure(error.localizedDescription)
            }

            let result: ProcessResult
            do {
                result = try ProcessRunner.run(
                    executable: pandocExecutable,
                    arguments: [
                        "--from=rtf",
                        "--to=html5",
                        "--extract-media=.",
                        "--wrap=preserve",
                        "--output", htmlURL.path,
                        preparedRTF.path,
                    ],
                    currentDirectory: workDirectory
                )
            } catch {
                throw ConversionError.pandocFailed(status: -1, message: error.localizedDescription)
            }
            guard result.status == 0 else {
                throw ConversionError.pandocFailed(
                    status: result.status,
                    message: result.standardError
                )
            }
        }
    }

    /// Schützt direkt aufeinanderfolgende `\\par`-Steuerwörter vor Pandocs
    /// Zusammenfaltung. Escapte Backslashes werden dabei nicht als Steuerwort
    /// interpretiert; das Quelldokument selbst bleibt unverändert.
    private func preservingEmptyRTFParagraphs(in data: Data, marker: String) -> Data {
        let bytes = [UInt8](data)
        let markerBytes = [UInt8](" \(marker)".utf8)
        var result = Data()
        result.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x5C, index + 1 < bytes.count else {
                result.append(bytes[index])
                index += 1
                continue
            }

            // RTF-Control-Symbole wie `\\\\` maskieren genau das Folgezeichen.
            // So kann dessen Backslash nicht irrtümlich als `\\par` beginnen.
            guard isASCIIAlpha(bytes[index + 1]) else {
                result.append(bytes[index])
                result.append(bytes[index + 1])
                index += 2
                continue
            }

            guard let control = rtfControlWord(in: bytes, at: index) else {
                result.append(bytes[index])
                index += 1
                continue
            }
            result.append(contentsOf: bytes[index..<control.end])
            if control.word == "bin", let byteCount = control.parameter, byteCount > 0 {
                var binaryStart = control.end
                if binaryStart < bytes.count, bytes[binaryStart] == 0x20 {
                    result.append(bytes[binaryStart])
                    binaryStart += 1
                }
                let binaryEnd = min(binaryStart + byteCount, bytes.count)
                result.append(contentsOf: bytes[binaryStart..<binaryEnd])
                index = binaryEnd
                continue
            }
            if control.word == "par",
               nextRTFControlWord(in: bytes, after: control.end)?.word == "par" {
                result.append(contentsOf: markerBytes)
            }
            index = control.end
        }
        return result
    }

    private func nextRTFControlWord(
        in bytes: [UInt8],
        after index: Int
    ) -> (word: String, end: Int, parameter: Int?)? {
        var next = index
        while next < bytes.count,
              bytes[next] == 0x20 || bytes[next] == 0x09
                || bytes[next] == 0x0A || bytes[next] == 0x0D {
            next += 1
        }
        return rtfControlWord(in: bytes, at: next)
    }

    private func rtfControlWord(
        in bytes: [UInt8],
        at index: Int
    ) -> (word: String, end: Int, parameter: Int?)? {
        guard index + 1 < bytes.count,
              bytes[index] == 0x5C,
              isASCIIAlpha(bytes[index + 1]) else {
            return nil
        }

        var end = index + 1
        while end < bytes.count, isASCIIAlpha(bytes[end]) {
            end += 1
        }
        let word = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
        let parameterStart = end
        if end < bytes.count, bytes[end] == 0x2D {
            end += 1
        }
        while end < bytes.count, bytes[end] >= 0x30, bytes[end] <= 0x39 {
            end += 1
        }
        let parameter: Int?
        if end > parameterStart,
           let value = Int(String(decoding: bytes[parameterStart..<end], as: UTF8.self)) {
            parameter = value
        } else {
            parameter = nil
        }
        return (word, end, parameter)
    }

    private func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
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

    private func warnings(
        inputURL: URL,
        kind: InputKind,
        referencedResourceNames: Set<String>,
        fileManager: FileManager
    ) -> [String] {
        guard kind == .rtfd else {
            if ColoredTextMarker.containsChromaticText(inRTF: inputURL) {
                return ["Chromatic text colors in RTF cannot be represented and were not preserved."]
            }
            return []
        }

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

    private enum InputKind {
        case rtf
        case rtfd
    }
}

/// Quellkompatibler Alias für Aufrufer der ursprünglichen RTFD-API.
public typealias RTFDConverter = RichTextConverter
