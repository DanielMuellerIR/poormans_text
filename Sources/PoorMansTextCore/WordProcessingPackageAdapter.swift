import Foundation

/// Gemeinsamer Pandoc-Adapter für die ZIP-Container DOCX und ODT.
struct WordProcessingPackageAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors: [SupportedFormat] = [
        SupportedFormat(
            format: .docx,
            fileExtensions: ["docx", "docm", "dotx", "dotm"],
            containerKind: .file,
            requiredTools: [.pandoc]
        ),
        SupportedFormat(
            format: .odt,
            fileExtensions: ["odt"],
            containerKind: .file,
            requiredTools: [.pandoc]
        ),
    ]

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .noMatch
        }

        let extensionFormat: InputFormat? = switch inputURL.pathExtension.lowercased() {
        case "docx", "docm", "dotx", "dotm": .docx
        case "odt": .odt
        default: nil
        }

        guard try ZIPArchiveInspector.looksLikeZIP(at: inputURL) else {
            if let extensionFormat {
                return .invalid(
                    format: extensionFormat,
                    priority: 110,
                    reason: "the ZIP package signature is missing"
                )
            }
            return .noMatch
        }

        do {
            guard let inspection = try ZIPArchiveInspector.inspectWordProcessingPackage(
                at: inputURL
            ) else {
                if let extensionFormat {
                    return .invalid(
                        format: extensionFormat,
                        priority: 110,
                        reason: "the required document-package entries are missing"
                    )
                }
                return .noMatch
            }
            return .match(
                AdapterInputInspection(
                    format: inspection.format,
                    priority: 110,
                    expectedWarnings: inspection.warnings
                )
            )
        } catch {
            if let extensionFormat {
                return .invalid(
                    format: extensionFormat,
                    priority: 110,
                    reason: error.localizedDescription
                )
            }
            return .noMatch
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        // Erst kopieren, dann prüfen, dann genau diese Kopie umwandeln: Der
        // Originalpfad könnte zwischen Prüfung und Pandoc-Lauf ausgetauscht
        // werden, sodass Pandoc andere als die geprüften Bytes bekäme.
        let stagedInputURL: URL
        let inspection: WordProcessingPackageInspection
        do {
            stagedInputURL = try ZIPArchiveInspector.stageVerifiedPackage(
                from: context.inputURL,
                into: context.workDirectory,
                named: "verified-source.\(context.format.rawValue)"
            )
            guard let detected = try ZIPArchiveInspector.inspectWordProcessingPackage(
                at: stagedInputURL
            ), detected.format == context.format else {
                throw ConversionError.invalidInput(
                    context.inputURL,
                    format: context.format,
                    reason: "the document package changed after inspection"
                )
            }
            inspection = detected
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: context.format,
                reason: error.localizedDescription
            )
        }

        if let reference = inspection.unsafeImageReferences.first {
            throw ConversionError.unsafeImageReference(reference)
        }

        let pandocExecutable = try PandocTool.resolve(context.options.pandocExecutable)
        let htmlURL = context.workDirectory.appendingPathComponent("document.html")
        var arguments = [
            "--sandbox",
            "--from=\(context.format.rawValue)",
            "--to=html5",
            "--extract-media=.",
            "--wrap=preserve",
        ]
        if context.format == .docx {
            arguments.append("--track-changes=accept")
        }
        arguments.append(contentsOf: [
            "--output", htmlURL.path,
            stagedInputURL.path,
        ])

        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                executable: pandocExecutable,
                arguments: arguments,
                currentDirectory: context.workDirectory
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

        let html: String
        do {
            html = try String(contentsOf: htmlURL, encoding: .utf8)
        } catch {
            // Pandoc hat mit 0 geendet — ein fehlendes oder unlesbares Ergebnis
            // ist deshalb kein Fehler des Quelldokuments.
            throw ConversionError.fileSystemFailure(
                "conversion produced no readable HTML: \(error.localizedDescription)"
            )
        }

        let converted = try HTMLDocumentConverter.convert(
            html: html,
            inputURL: context.inputURL,
            format: context.format,
            resourceDirectory: context.workDirectory,
            stagedOutputDirectory: context.stagedOutputDirectory,
            pandocExecutable: pandocExecutable
        )
        return StagedConversionResult(
            markdownRelativePath: converted.markdownRelativePath,
            assetRelativePaths: converted.assetRelativePaths,
            warnings: inspection.warnings
        )
    }
}
