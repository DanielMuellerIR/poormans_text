import Foundation

/// Nativer Tabellenimport. Alle Formate enden im selben Workbook-Modell und
/// benutzen denselben Renderer; nur Paket- beziehungsweise OLE-Leser sind
/// formatspezifisch.
struct SpreadsheetAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors: [SupportedFormat] = [
        SupportedFormat(
            format: .ods,
            fileExtensions: ["ods"],
            containerKind: .file,
            requiredTools: []
        ),
        SupportedFormat(
            format: .xlsx,
            fileExtensions: ["xlsx"],
            containerKind: .file,
            requiredTools: []
        ),
        SupportedFormat(
            format: .xls,
            fileExtensions: ["xls"],
            containerKind: .file,
            requiredTools: []
        ),
    ]

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .noMatch
        }

        let extensionFormat: InputFormat? = switch inputURL.pathExtension.lowercased() {
        case "ods": .ods
        case "xlsx": .xlsx
        case "xls": .xls
        default: nil
        }
        guard try ZIPArchiveInspector.looksLikeZIP(at: inputURL) else {
            do {
                let values = try inputURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                )
                if values.isRegularFile == true,
                   let size = values.fileSize,
                   size <= 1_073_741_824 {
                    let data = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
                    if LegacyXLSWorkbookParser.looksLikeXLS(data) {
                        let workbook = try LegacyXLSWorkbookParser.parse(data)
                        return .match(
                            AdapterInputInspection(
                                format: .xls,
                                priority: 108,
                                expectedWarnings: warnings(for: workbook, format: .xls)
                            )
                        )
                    }
                }
            } catch {
                if extensionFormat == .xls {
                    return .invalid(
                        format: .xls,
                        priority: 108,
                        reason: error.localizedDescription
                    )
                }
            }
            return extensionFormat.map {
                .invalid(
                    format: $0,
                    priority: 108,
                    reason: "the ZIP package signature is missing"
                )
            } ?? .noMatch
        }

        do {
            let package = try ZIPArchiveInspector.packageContents(
                at: inputURL,
                entryNames: ["mimetype", "content.xml"]
            )
            if package.entryNames.contains("mimetype"),
               package.entryNames.contains("content.xml"),
               let mimetype = package.entries["mimetype"].map({
                      String(decoding: $0, as: UTF8.self)
                          .trimmingCharacters(in: .whitespacesAndNewlines)
                  }),
               mimetype == "application/vnd.oasis.opendocument.spreadsheet" {
                let workbook = try ODSWorkbookParser.parse(package.entries["content.xml"]!)
                return .match(
                    AdapterInputInspection(
                        format: .ods,
                        priority: 108,
                        expectedWarnings: warnings(for: workbook, format: .ods)
                    )
                )
            }
            if try XLSXWorkbookParser.looksLikeXLSX(packageAt: inputURL) {
                let workbook = try XLSXWorkbookParser.parse(packageAt: inputURL)
                return .match(
                    AdapterInputInspection(
                        format: .xlsx,
                        priority: 108,
                        expectedWarnings: warnings(for: workbook, format: .xlsx)
                    )
                )
            }
            return extensionFormat.map {
                .invalid(
                    format: $0,
                    priority: 108,
                    reason: "the required spreadsheet-package metadata is missing or invalid"
                )
            } ?? .noMatch
        } catch {
            return extensionFormat.map {
                .invalid(
                    format: $0,
                    priority: 108,
                    reason: error.localizedDescription
                )
            } ?? .noMatch
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        guard context.format == .ods || context.format == .xlsx || context.format == .xls else {
            throw ConversionError.unsupportedInput(context.inputURL)
        }
        let stagedInput: URL
        let workbook: SpreadsheetWorkbook
        do {
            if context.format == .xls {
                stagedInput = context.workDirectory.appendingPathComponent("verified-source.xls")
                let values = try context.inputURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                )
                guard values.isRegularFile == true,
                      let size = values.fileSize,
                      size <= 1_073_741_824 else {
                    throw SpreadsheetError("the XLS source is not a supported regular file")
                }
                try FileManager.default.copyItem(at: context.inputURL, to: stagedInput)
                workbook = try LegacyXLSWorkbookParser.parse(
                    Data(contentsOf: stagedInput, options: [.mappedIfSafe])
                )
            } else {
                stagedInput = try ZIPArchiveInspector.stageVerifiedPackage(
                    from: context.inputURL,
                    into: context.workDirectory,
                    named: "verified-source.\(context.format.rawValue)"
                )
                if context.format == .ods {
                    let package = try ZIPArchiveInspector.packageContents(
                        at: stagedInput,
                        entryNames: ["mimetype", "content.xml"]
                    )
                    guard let content = package.entries["content.xml"],
                          let mimetype = package.entries["mimetype"].map({
                              String(decoding: $0, as: UTF8.self)
                                  .trimmingCharacters(in: .whitespacesAndNewlines)
                          }),
                          mimetype == "application/vnd.oasis.opendocument.spreadsheet" else {
                        throw SpreadsheetError("the verified ODS package changed after inspection")
                    }
                    workbook = try ODSWorkbookParser.parse(content)
                } else {
                    guard try XLSXWorkbookParser.looksLikeXLSX(packageAt: stagedInput) else {
                        throw SpreadsheetError("the verified XLSX package changed after inspection")
                    }
                    workbook = try XLSXWorkbookParser.parse(packageAt: stagedInput)
                }
            }
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: context.format,
                reason: error.localizedDescription
            )
        }

        let markdownName = context.inputURL.deletingPathExtension().lastPathComponent + ".md"
        let markdownURL = context.stagedOutputDirectory.appendingPathComponent(markdownName)
        let markdown: String
        do {
            markdown = try SpreadsheetMarkdownRenderer.render(
                workbook,
                sourceURL: context.inputURL,
                style: context.options.spreadsheetRendering
            )
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: context.format,
                reason: error.localizedDescription
            )
        }
        do {
            try Data(markdown.utf8).write(to: markdownURL, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        return StagedConversionResult(
            markdownRelativePath: markdownName,
            assetRelativePaths: [],
            warnings: warnings(for: workbook, format: context.format)
        )
    }

    private func warnings(
        for workbook: SpreadsheetWorkbook,
        format: InputFormat
    ) -> [ConversionWarning] {
        var result = [ConversionWarning]()
        if workbook.hasFlattenedMerges {
            result.append(.spreadsheetMergesFlattened)
        }
        if workbook.hasFormulaWithoutResult {
            result.append(.spreadsheetFormulaResultMissing)
        }
        if workbook.hasUnsupportedObjects {
            result.append(.spreadsheetUnsupportedObjects)
        }
        if format == .xls {
            result.append(.legacySpreadsheetPotentialLoss)
        }
        return result
    }

    private struct SpreadsheetError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}
