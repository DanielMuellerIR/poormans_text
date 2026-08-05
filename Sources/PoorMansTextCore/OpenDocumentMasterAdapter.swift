import Foundation

/// Löst ausschließlich lokale, neben dem Masterdokument liegende ODT-Teile auf.
/// Jeder Teil läuft anschließend durch denselben geprüften ODT-Adapter wie eine
/// einzeln übergebene Datei; entfernte oder aus dem Dokumentverbund ausbrechende
/// Verweise werden nie geöffnet.
struct OpenDocumentMasterAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors: [SupportedFormat] = [
        SupportedFormat(
            format: .odm,
            fileExtensions: ["odm"],
            containerKind: .file,
            requiredTools: [.pandoc]
        )
    ]

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .noMatch
        }
        let hasODMExtension = inputURL.pathExtension.lowercased() == "odm"
        guard try ZIPArchiveInspector.looksLikeZIP(at: inputURL) else {
            return hasODMExtension
                ? .invalid(format: .odm, priority: 109, reason: "the ZIP package signature is missing")
                : .noMatch
        }

        do {
            let package = try masterPackage(at: inputURL)
            guard package.isMaster else {
                return hasODMExtension
                    ? .invalid(
                        format: .odm,
                        priority: 109,
                        reason: "the OpenDocument master mimetype or content.xml is missing"
                    )
                    : .noMatch
            }
            let items = try ODMContentParser.parse(package.content)
            let warnings = try inspectLinkedDocuments(items, masterURL: inputURL)
            return .match(
                AdapterInputInspection(
                    format: .odm,
                    priority: 109,
                    expectedWarnings: warnings
                )
            )
        } catch {
            return hasODMExtension
                ? .invalid(format: .odm, priority: 109, reason: error.localizedDescription)
                : .noMatch
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        let stagedMaster: URL
        let items: [ODMContentItem]
        do {
            stagedMaster = try ZIPArchiveInspector.stageVerifiedPackage(
                from: context.inputURL,
                into: context.workDirectory,
                named: "verified-source.odm"
            )
            let package = try masterPackage(at: stagedMaster)
            guard package.isMaster else {
                throw MasterError("the verified ODM package changed after inspection")
            }
            items = try ODMContentParser.parse(package.content)
            _ = try inspectLinkedDocuments(items, masterURL: context.inputURL)
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .odm,
                reason: error.localizedDescription
            )
        }

        var sections = ["# \(context.inputURL.deletingPathExtension().lastPathComponent)"]
        var warnings = [ConversionWarning.openDocumentMasterFlattened]
        var assetRelativePaths = [String]()
        var linkedIndex = 0

        for item in items {
            switch item {
            case .markdown(let markdown):
                sections.append(markdown)
            case .section(let name, let reference):
                linkedIndex += 1
                let linkedURL: URL
                do {
                    linkedURL = try resolve(reference, relativeTo: context.inputURL)
                } catch {
                    throw ConversionError.invalidInput(
                        context.inputURL,
                        format: .odm,
                        reason: error.localizedDescription
                    )
                }
                let heading = name?.trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(
                    "## Section: \((heading?.isEmpty == false ? heading : nil) ?? linkedURL.deletingPathExtension().lastPathComponent)"
                )
                let child = try convertLinkedDocument(
                    linkedURL,
                    index: linkedIndex,
                    context: context
                )
                var childMarkdown = child.markdown
                for asset in child.assets {
                    let sourceName = asset.source.lastPathComponent
                    let targetName = String(format: "section%02d-%@", linkedIndex, sourceName)
                    let imageDirectory = context.stagedOutputDirectory.appendingPathComponent(
                        "images",
                        isDirectory: true
                    )
                    do {
                        try FileManager.default.createDirectory(
                            at: imageDirectory,
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.copyItem(
                            at: asset.source,
                            to: imageDirectory.appendingPathComponent(targetName)
                        )
                    } catch {
                        throw ConversionError.fileSystemFailure(error.localizedDescription)
                    }
                    childMarkdown = childMarkdown.replacingOccurrences(
                        of: asset.relativePath,
                        with: "images/\(targetName)"
                    )
                    assetRelativePaths.append("images/\(targetName)")
                }
                sections.append(childMarkdown.trimmingCharacters(in: .newlines))
                appendUnique(child.warnings, to: &warnings)
            }
        }

        let markdownName = context.inputURL.deletingPathExtension().lastPathComponent + ".md"
        let markdownURL = context.stagedOutputDirectory.appendingPathComponent(markdownName)
        do {
            try Data((sections.joined(separator: "\n\n") + "\n").utf8)
                .write(to: markdownURL, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        return StagedConversionResult(
            markdownRelativePath: markdownName,
            assetRelativePaths: assetRelativePaths,
            warnings: warnings
        )
    }

    private func masterPackage(at url: URL) throws -> (isMaster: Bool, content: Data) {
        let package = try ZIPArchiveInspector.packageContents(
            at: url,
            entryNames: ["mimetype", "content.xml"]
        )
        guard let content = package.entries["content.xml"] else {
            return (false, Data())
        }
        let mimetype = package.entries["mimetype"].map {
            String(decoding: $0, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (mimetype == "application/vnd.oasis.opendocument.text-master", content)
    }

    private func inspectLinkedDocuments(
        _ items: [ODMContentItem],
        masterURL: URL
    ) throws -> [ConversionWarning] {
        var warnings = [ConversionWarning.openDocumentMasterFlattened]
        let adapter = WordProcessingPackageAdapter()
        for item in items {
            guard case .section(_, let reference) = item else { continue }
            let url = try resolve(reference, relativeTo: masterURL)
            switch try adapter.inspectInput(at: url) {
            case .match(let inspection) where inspection.format == .odt:
                appendUnique(inspection.expectedWarnings, to: &warnings)
            case .invalid(_, _, let reason):
                throw MasterError("linked document is invalid (\(reference)): \(reason)")
            default:
                throw MasterError("linked master-document section is not an ODT file: \(reference)")
            }
        }
        return warnings
    }

    private func resolve(_ reference: String, relativeTo masterURL: URL) throws -> URL {
        guard let components = URLComponents(string: reference),
              components.scheme == nil,
              components.host == nil,
              components.query == nil,
              let decodedPath = components.percentEncodedPath.removingPercentEncoding,
              !decodedPath.isEmpty,
              !decodedPath.hasPrefix("/"),
              !decodedPath.contains("\\") else {
            throw MasterError("unsafe or non-local ODM section reference: \(reference)")
        }
        let pathComponents = NSString(string: decodedPath).pathComponents
        guard !pathComponents.contains("..") else {
            throw MasterError("ODM section reference leaves the document bundle: \(reference)")
        }

        let base = masterURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(decodedPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw MasterError("linked ODM section is missing: \(reference)")
        }
        let resolved = candidate.resolvingSymlinksInPath()
        let basePrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard resolved.path.hasPrefix(basePrefix) else {
            throw MasterError("linked ODM section escapes through a symbolic link: \(reference)")
        }
        return resolved
    }

    private func convertLinkedDocument(
        _ url: URL,
        index: Int,
        context: AdapterConversionContext
    ) throws -> (markdown: String, assets: [(source: URL, relativePath: String)], warnings: [ConversionWarning]) {
        let childRoot = context.workDirectory.appendingPathComponent("odm-section-\(index)")
        let childWork = childRoot.appendingPathComponent("work", isDirectory: true)
        let childOutput = childRoot.appendingPathComponent("result", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: childWork, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: childOutput, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        let result = try WordProcessingPackageAdapter().convert(
            AdapterConversionContext(
                inputURL: url,
                format: .odt,
                workDirectory: childWork,
                stagedOutputDirectory: childOutput,
                options: context.options
            )
        )
        let markdownURL = childOutput.appendingPathComponent(result.markdownRelativePath)
        let markdown: String
        do {
            markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        let assets = result.assetRelativePaths.map {
            (childOutput.appendingPathComponent($0), $0)
        }
        return (markdown, assets, result.warnings)
    }

    private func appendUnique(
        _ additions: [ConversionWarning],
        to warnings: inout [ConversionWarning]
    ) {
        for warning in additions where !warnings.contains(warning) {
            warnings.append(warning)
        }
    }

    private struct MasterError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}
