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
            guard let inspection = try WordProcessingPackageInspector.inspect(
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
        let reader: ZIPPackageReader
        let inspection: WordProcessingPackageInspection
        do {
            // Gestagt wird ueber `resolvedInputURL`, den EINMAL zentral
            // aufgeloesten Pfad. Mit dem symbolischen `inputURL` konnte ein
            // Verweis nach der Erkennung, aber vor dem Staging umgehaengt
            // werden — der Adapter las dann ein anderes Dokument als das
            // gepruefte (Review-Fund 2026-08-25).
            reader = try ZIPArchiveInspector.openVerifiedPackage(
                from: context.resolvedInputURL,
                into: context.workDirectory,
                named: "verified-source.\(context.format.rawValue)"
            )
            stagedInputURL = reader.url
            guard let detected = try WordProcessingPackageInspector.inspect(
                reader: reader
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

        var review: DOCXReviewPreserver?
        if context.format == .docx && (inspection.containsComments || inspection.containsTrackedChanges) {
            let preserver = DOCXReviewPreserver()
            do {
                guard let mainPart = try WordProcessingPackageInspector.mainDocumentPart(reader: reader, entryNames: reader.entryNames) else {
                    throw ImportFailure("the DOCX main part is missing")
                }
                try preserver.prepare(reader: reader, mainPart: mainPart, mode: context.options.docxChangeMode, workDirectory: context.workDirectory)
                review = preserver
            } catch let error as ConversionError { throw error }
            catch { throw ConversionError.invalidInput(context.inputURL, format: .docx, reason: error.localizedDescription) }
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
            let mode = context.options.docxChangeMode
            arguments.append("--track-changes=\(mode == .mark ? "all" : mode.rawValue)")
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
        try review?.finish(markdownURL: context.stagedOutputDirectory.appendingPathComponent(converted.markdownRelativePath))
        var warnings = inspection.warnings.filter { $0.code != "docx.commentsPresent" &&
            !(context.format == .docx && context.options.docxChangeMode != .accept && $0.code == "wordProcessing.changesAccepted") }
        if context.format == .docx, inspection.containsTrackedChanges, context.options.docxChangeMode != .accept {
            warnings.append(.init(code: context.options.docxChangeMode == .reject ? "docx.changesRejected" : "docx.changesMarked",
                message: context.options.docxChangeMode == .reject ? "Tracked DOCX text changes were rejected." : "Tracked DOCX text changes were visibly marked with their available author and date.", kind: .information))
        }
        warnings += review?.warnings ?? []
        return StagedConversionResult(
            markdownRelativePath: converted.markdownRelativePath,
            assetRelativePaths: converted.assetRelativePaths,
            warnings: warnings,
            metadata: PackageMetadataParser.read(
                from: reader,
                entryName: context.format == .odt ? "meta.xml" : "docProps/core.xml"
            )
        )
    }
}
