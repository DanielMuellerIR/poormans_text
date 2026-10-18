import Foundation

struct ENEXAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors = [SupportedFormat(format: .enex, fileExtensions: ["enex"], containerKind: .file, requiredTools: [.pandoc])]
    private static let priority = 190

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let named = inputURL.pathExtension.lowercased() == "enex"
        do {
            let data = try VerifiedFileStaging.prefix(of: inputURL, maximumBytes: ENEXReader.maximumSourceBytes,
                prefixBytes: 32_768, describedAs: "the ENEX export")
            // Die begrenzte Probe kann mitten in einem UTF-8-Zeichen enden.
            let text = (0...min(3, data.count)).lazy.compactMap { String(data: data.dropLast($0), encoding: .utf8) }.first
            guard let text else { throw ImportFailure("ENEX requires UTF-8") }
            _ = try ENEXXML.prepared(text, root: "en-export")
            return .match(.init(format: .enex, priority: Self.priority, expectedWarnings: []))
        } catch let error as ConversionError { throw error }
        catch { return named ? .invalid(format: .enex, priority: Self.priority, reason: error.localizedDescription) : .noMatch }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        do {
            let data = try VerifiedFileStaging.contents(of: context.resolvedInputURL, maximumBytes: ENEXReader.maximumSourceBytes, describedAs: "the ENEX export")
            let archive = try ENEXReader.read(data)
            let noteLinks = ENEXNoteLinks(notes: archive.notes)
            var resourceBudget = ENEXResources.Budget()
            var writer = CollectionOutputWriter(context: context)
            for note in archive.notes {
                try ConversionExecution.report(.init(phase: .converting, format: .enex, unit: .note, completed: note.index - 1, total: archive.notes.count))
                try writer.append(title: note.title, metadata: note.metadata, location: .init(note: String(note.index))) { child in
                    let resources = try ENEXResources.stage(note, context: child, budget: &resourceBudget)
                    var normalizer = ENMLConverter(resources: resources, noteLinks: noteLinks,
                        markdownName: child.inputURL.deletingPathExtension().lastPathComponent + ".md")
                    let html = try normalizer.convert(note.content)
                    let resolved = try HTMLImageSourceResolver.resolve(html: html, baseDirectory: nil, baseURL: nil,
                        subresources: resources.subresources, workDirectory: child.workDirectory)
                    let converted = try HTMLDocumentConverter.convert(html: resolved.html, inputURL: child.inputURL,
                        format: .enex, resourceDirectory: child.workDirectory, stagedOutputDirectory: child.stagedOutputDirectory,
                        pandocExecutable: PandocTool.resolve(child.options.pandocExecutable))
                    var warnings = note.warnings + (noteLinks.warnings[note.index] ?? []) + resources.warnings + normalizer.warnings + [.htmlStructureSimplified]
                    if resolved.remoteImagesKeptAsLinks > 0 { warnings.append(.remoteImagesKeptAsLinks(resolved.remoteImagesKeptAsLinks)) }
                    if resolved.missingImagesDropped > 0 { warnings.append(.missingImagesDropped(resolved.missingImagesDropped)) }
                    let known: Set<String> = ["title", "content", "created", "updated", "tag", "note-attributes", "task", "resource", "guid"]
                    let unknown = note.node.children.filter { !known.contains($0.name) || !$0.namespace.isEmpty }
                    if !unknown.isEmpty || !Set(note.node.attributes.keys).subtracting(["|guid"]).isEmpty { warnings.append(.init(code: "enex.unknownFieldsRetained", message: "Unknown ENEX fields were retained in the source metadata table.", kind: .approximation)) }
                    let url = child.stagedOutputDirectory.appendingPathComponent(converted.markdownRelativePath)
                    try ConversionPostprocessor.prepend("# " + MarkdownEscaping.inlineLiteral(note.title) + "\n\n" + (try Self.metadataTable(note.node, excluding: ["title", "content", "resource", "task"])), to: url)
                    let tasks = note.node.elements("task", namespace: "")
                    if !tasks.isEmpty {
                        var markdown = try String(contentsOf: url, encoding: .utf8)
                        markdown += "\n\n## Tasks\n\n"
                        for task in tasks {
                            let title = try ENEXReader.field("title", in: task) ?? ""
                            let status = try ENEXReader.field("taskStatus", in: task) ?? ""
                            let state = status == "completed" ? "[x]" : status == "open" ? "[ ]" : "[?]"
                            markdown += "- " + state + " " + MarkdownEscaping.inlineLiteral(title) + "\n\n"
                            markdown += try Self.metadataTable(task, excluding: ["title"])
                            guard markdown.utf8.count <= CollectionLimits.maximumDocumentBytes else { throw ImportFailure("ENEX task output exceeds its size limit") }
                        }
                        warnings.append(.init(code: "enex.tasksFlattened", message: "ENEX tasks were retained as static entries in export order with their source fields; grouping and task actions are not reproduced.", kind: .approximation))
                        try Data(markdown.utf8).write(to: url, options: .atomic)
                    }
                    if !resources.appendix.isEmpty {
                        var markdown = try String(contentsOf: url, encoding: .utf8)
                        markdown += resources.appendix
                        guard markdown.utf8.count <= CollectionLimits.maximumDocumentBytes else { throw ImportFailure("ENEX resource output exceeds its size limit") }
                        try Data(markdown.utf8).write(to: url, options: .atomic)
                    }
                    return .init(markdownRelativePath: converted.markdownRelativePath, assetRelativePaths: converted.assetRelativePaths + resources.assetPaths,
                        warnings: warnings, metadata: note.metadata)
                }
            }
            return try writer.finish(metadata: .init(title: context.inputURL.deletingPathExtension().lastPathComponent))
        } catch let error as ConversionError { throw error }
        catch { throw ConversionError.invalidInput(context.inputURL, format: .enex, reason: error.localizedDescription) }
    }

    static func metadataTable(_ root: ImportXML, excluding: Set<String>) throws -> String {
        var rows: [(String, String)] = []
        var bytes = 0
        func append(_ name: String, _ value: String) throws {
            bytes += name.utf8.count + value.utf8.count
            guard bytes <= CollectionLimits.maximumDocumentMetadataBytes else { throw ImportFailure("ENEX source fields exceed their size limit") }
            rows.append((name, value))
        }
        func visit(_ node: ImportXML, path: String) throws {
            try ConversionExecution.check()
            for (key, value) in node.attributes.sorted(by: { $0.key < $1.key }) { try append(path + "/@" + key, value) }
            if node.children.isEmpty { try append(path, node.text) }
            else {
                let direct = node.content.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined()
                if !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try append(path, direct) }
                for child in node.children { try visit(child, path: path + "/" + child.name) }
            }
        }
        for (key, value) in root.attributes.sorted(by: { $0.key < $1.key }) { try append("@" + key, value) }
        for child in root.children where !excluding.contains(child.name) { try visit(child, path: child.name) }
        guard !rows.isEmpty else { return "" }
        return "| Source field | Value |\n| --- | --- |\n" + rows.map { name, value in
            let text = value.components(separatedBy: .controlCharacters).joined(separator: " ")
            return "| " + MarkdownEscaping.inlineLiteral(name) + " | " + MarkdownEscaping.inlineLiteral(text) + " |\n"
        }.joined() + "\n"
    }
}
