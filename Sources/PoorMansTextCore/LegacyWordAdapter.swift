import Foundation

/// Eigenständiger Importweg für das alte OLE-basierte Word-DOC-Format.
struct LegacyWordAdapter: DocumentConversionAdapter {
    /// Fester Systempfad — `textutil` gehört zu macOS und wird nie im PATH gesucht.
    /// Auch die Verfügbarkeitsprüfung des Formatkatalogs benutzt genau diesen Pfad.
    static let textutilPath = "/usr/bin/textutil"

    let supportedFormatDescriptors: [SupportedFormat] = [
        SupportedFormat(
            format: .doc,
            fileExtensions: ["doc"],
            containerKind: .file,
            // Erst `textutil` nach HTML, danach dieselbe Pandoc-Stufe wie RTF.
            requiredTools: [.textutil, .pandoc]
        )
    ]

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .noMatch
        }

        let hasDOCExtension = inputURL.pathExtension.lowercased() == "doc"
        guard try hasCompoundDocumentSignature(at: inputURL) else {
            return hasDOCExtension
                ? .invalid(
                    format: .doc,
                    priority: 105,
                    reason: "the OLE compound-document signature is missing"
                )
                : .noMatch
        }

        let info: ProcessResult
        do {
            info = try ProcessRunner.run(
                executable: URL(fileURLWithPath: Self.textutilPath),
                arguments: ["-info", "--", inputURL.path],
                currentDirectory: FileManager.default.temporaryDirectory,
                captureStandardOutput: true
            )
        } catch {
            return hasDOCExtension
                ? .invalid(
                    format: .doc,
                    priority: 105,
                    reason: "textutil could not inspect the compound document"
                )
                : .noMatch
        }

        guard info.status == 0, isWordFormat(info.standardOutput) else {
            return hasDOCExtension
                ? .invalid(
                    format: .doc,
                    priority: 105,
                    reason: "the compound document is not a Word DOC file"
                )
                : .noMatch
        }

        return .match(
            AdapterInputInspection(
                format: .doc,
                priority: 105,
                expectedWarnings: [.legacyWordPotentialLoss]
            )
        )
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        let pandocExecutable = try PandocTool.resolve(context.options.pandocExecutable)
        let htmlURL = context.workDirectory.appendingPathComponent("document.html")
        let referenceTextURL = context.workDirectory.appendingPathComponent("reference.txt")

        // Erst kopieren, dann beide Läufe auf der Kopie: Der Originalpfad könnte
        // zwischen Prüfung und Lauf ausgetauscht werden, und HTML-Lauf wie
        // TXT-Referenzlauf müssen zwingend dieselben Bytes sehen — sonst
        // vergliche die Textprüfung am Ende zwei verschiedene Dokumente.
        let stagedInputURL = context.workDirectory.appendingPathComponent("verified-source.doc")
        do {
            let values = try context.inputURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size <= 1_073_741_824 else {
                throw ConversionError.invalidInput(
                    context.inputURL,
                    format: .doc,
                    reason: "the DOC source is not a supported regular file"
                )
            }
            try FileManager.default.copyItem(at: context.inputURL, to: stagedInputURL)
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .doc,
                reason: error.localizedDescription
            )
        }

        try runTextutil(
            arguments: [
                "-convert", "html",
                "-noload",
                "-output", htmlURL.path,
                "--", stagedInputURL.path,
            ],
            currentDirectory: context.workDirectory
        )
        try runTextutil(
            arguments: [
                "-convert", "txt",
                "-encoding", "UTF-8",
                // Keine Subressourcen nachladen; der reine Referenztext braucht sie nicht.
                "-noload",
                "-output", referenceTextURL.path,
                "--", stagedInputURL.path,
            ],
            currentDirectory: context.workDirectory
        )

        let html: String
        let referenceText: String
        do {
            html = try String(contentsOf: htmlURL, encoding: .utf8)
            referenceText = try String(contentsOf: referenceTextURL, encoding: .utf8)
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .doc,
                reason: "textutil produced no readable document content"
            )
        }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .doc,
                reason: "textutil produced empty HTML"
            )
        }

        let converted = try HTMLDocumentConverter.convert(
            html: html,
            inputURL: context.inputURL,
            format: .doc,
            resourceDirectory: context.workDirectory,
            stagedOutputDirectory: context.stagedOutputDirectory,
            pandocExecutable: pandocExecutable
        )
        let markdownURL = context.stagedOutputDirectory.appendingPathComponent(
            converted.markdownRelativePath
        )
        let markdown: String
        do {
            markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .doc,
                reason: "conversion produced no readable Markdown"
            )
        }
        try verifyTextContent(referenceText: referenceText, markdown: markdown, inputURL: context.inputURL)

        return StagedConversionResult(
            markdownRelativePath: converted.markdownRelativePath,
            assetRelativePaths: converted.assetRelativePaths,
            warnings: [.legacyWordPotentialLoss]
        )
    }

    private func runTextutil(arguments: [String], currentDirectory: URL) throws {
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                executable: URL(fileURLWithPath: Self.textutilPath),
                arguments: arguments,
                currentDirectory: currentDirectory
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
    }

    private func hasCompoundDocumentSignature(at inputURL: URL) throws -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: inputURL)
            defer {
                try? handle.close()
            }
            return [UInt8](try handle.read(upToCount: 8) ?? Data())
                == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
    }

    private func isWordFormat(_ textutilInfo: String) -> Bool {
        textutilInfo.components(separatedBy: .newlines).contains {
            let fields = $0.split(separator: ":", maxSplits: 1)
            return fields.count == 2
                && fields[0].trimmingCharacters(in: .whitespaces) == "Type"
                && fields[1].trimmingCharacters(in: .whitespaces) == "Word format"
        }
    }

    private func verifyTextContent(
        referenceText: String,
        markdown: String,
        inputURL: URL
    ) throws {
        let referenceWords = words(in: referenceText)
        guard !referenceWords.isEmpty else {
            return
        }
        let markdownWords = words(in: markdown)
        var availableWords = Dictionary(markdownWords.map { (String($0), 1) }) { $0 + $1 }
        let retainedCount = referenceWords.reduce(into: 0) { count, word in
            let key = String(word)
            guard let available = availableWords[key], available > 0 else {
                return
            }
            count += 1
            availableWords[key] = available - 1
        }
        let minimumCount = max(1, referenceWords.count * 4 / 5)
        guard retainedCount >= minimumCount else {
            throw ConversionError.invalidInput(
                inputURL,
                format: .doc,
                reason: "the generated Markdown contains substantially less text than textutil extracted"
            )
        }
    }

    private func words(in text: String) -> [Substring] {
        text.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }
    }
}
