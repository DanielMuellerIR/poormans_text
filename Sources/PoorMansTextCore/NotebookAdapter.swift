import Foundation

/// Notebook-Zellen sind Daten. Dieser Adapter startet weder Kernel noch Prozesse
/// und öffnet keine aus Markdown oder Outputs referenzierten Ressourcen.
struct NotebookAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors = [SupportedFormat(format: .ipynb, fileExtensions: ["ipynb"], containerKind: .file, requiredTools: [])]
    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        guard inputURL.pathExtension.lowercased() == "ipynb" else { return .noMatch }
        do {
            _ = try read(inputURL)
            return .match(AdapterInputInspection(format: .ipynb, priority: 115, expectedWarnings: []))
        } catch {
            try ConversionExecution.check()
            return .invalid(format: .ipynb, priority: 115, reason: error.localizedDescription)
        }
    }
    private func read(_ input: URL) throws -> [String: Any] {
        try VerifiedFileStaging.withTemporaryCopy(of: input, maximumBytes: 64 * 1_024 * 1_024, describedAs: "the notebook source", fileExtension: "ipynb") { copy in
            let data = try Data(contentsOf: copy)
            try ConversionExecution.check()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["nbformat"] as? Int == 4, let cells = root["cells"] as? [[String: Any]], cells.count <= 10_000 else { throw ImportFailure("a notebook must be version 4 with at most 10,000 cells") }
            return root
        }
    }
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        do {
            let root = try read(context.resolvedInputURL)
            let importer = NotebookImport(output: context.stagedOutputDirectory)
            let text = try importer.convert(root, title: context.inputURL.deletingPathExtension().lastPathComponent)
            let filename = context.inputURL.deletingPathExtension().lastPathComponent + ".md"
            try Data(text.utf8).write(to: context.stagedOutputDirectory.appendingPathComponent(filename), options: .atomic)
            return StagedConversionResult(markdownRelativePath: filename, assetRelativePaths: importer.media.paths, warnings: importer.diagnostics.result)
        } catch {
            try ConversionExecution.check()
            throw ConversionError.invalidInput(context.inputURL, format: .ipynb, reason: error.localizedDescription)
        }
    }
}

final class NotebookImport {
    let media: ImportMediaStore
    var diagnostics = ImportDiagnostics()
    private var cellNumber = 0
    init(output: URL) { media = ImportMediaStore(output: output) }
    func convert(_ root: [String: Any], title: String) throws -> String {
        guard let cells = root["cells"] as? [[String: Any]] else { throw ImportFailure("invalid notebook cells") }
        let metadata = root["metadata"] as? [String: Any] ?? [:]
        let language = (metadata["language_info"] as? [String: Any])?["name"] as? String
            ?? (metadata["kernelspec"] as? [String: Any])?["language"] as? String ?? "text"
        let safeLanguage = language.count <= 64 && language.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 45, 95].contains($0) } ? language : "text"
        if safeLanguage != language { diagnostics.add("notebook.languageNotRepresented", "The notebook language name is not a safe Markdown fence label; text was used.") }
        var markdown = "# " + MarkdownEscaping.heading(title) + "\n\n"
        var bytes = markdown.utf8.count
        func append(_ text: String) throws {
            guard text.utf8.count <= 128 * 1_024 * 1_024 - bytes else { throw ImportFailure("notebook Markdown exceeds 128 MiB") }
            markdown += text; bytes += text.utf8.count
        }
        var outputCount = 0
        for (index, cell) in cells.enumerated() {
            cellNumber = index + 1
            try ConversionExecution.report(unit: .cell, completed: index, total: cells.count)
            let source = try string(cell["source"])
            switch cell["cell_type"] as? String {
            case "markdown":
                let attachments = cell["attachments"] as? [String: Any] ?? [:]
                var paths: [String: String] = [:]
                for name in attachments.keys.sorted() {
                    try ConversionExecution.check()
                    guard let representations = attachments[name] as? [String: Any] else { warn("attachmentUnavailable", "Invalid attachment: \(name)"); continue }
                    if let path = try image(representations) { paths["attachment:" + name] = path }
                }
                try append(try markdownResources(source, attachments: paths) + "\n\n")
            case "code":
                try append(Self.fence(source, language: safeLanguage) + "\n\n")
                guard cell["outputs"] == nil || cell["outputs"] is [[String: Any]] else { throw ImportFailure("invalid notebook outputs in cell \(cellNumber)") }
                let outputs = cell["outputs"] as? [[String: Any]] ?? []
                outputCount += outputs.count
                guard outputCount <= 100_000, outputs.count <= 10_000 else { throw ImportFailure("notebook cell exceeds 10,000 outputs") }
                for output in outputs {
                    try ConversionExecution.check()
                    switch output["output_type"] as? String {
                    case "stream": try append(Self.fence(try string(output["text"]), language: "text") + "\n\n")
                    case "execute_result", "display_data":
                        guard let data = output["data"] as? [String: Any] else { throw ImportFailure("invalid MIME output in cell \(cellNumber)") }
                        if let value = data["text/plain"] { try append(Self.fence(try string(value), language: "text") + "\n\n") }
                        if let path = try image(data) { try append("![Notebook output](\(path))\n\n") }
                        let unsupported = data.keys.filter { $0 != "text/plain" && !$0.hasPrefix("image/") }.sorted()
                        if !unsupported.isEmpty { warn("outputNotRepresented", "Output representations are not rendered: \(unsupported.joined(separator: ", ")).") }
                    case "error":
                        let text = try traceback(output["traceback"])
                        let fallback = (output["ename"] as? String ?? "Error") + ": " + (output["evalue"] as? String ?? "")
                        try append(Self.fence(text.isEmpty ? fallback : text, language: "text") + "\n\n")
                    default: warn("outputNotRepresented", "An unknown notebook output type is not rendered.")
                    }
                }
            case "raw":
                try append(Self.fence(source, language: "text") + "\n\n")
                warn("rawCellPreservedAsText", "Raw cell content is preserved as text; its target format is not interpreted.")
            default:
                try append(Self.fence(source, language: "text") + "\n\n")
                warn("cellTypeNotRepresented", "An unknown cell type is preserved as text.")
            }
        }
        try ConversionExecution.report(unit: .cell, completed: cells.count, total: cells.count)
        return markdown
    }
    private func warn(_ code: String, _ text: String) { diagnostics.add("notebook." + code, text, cell: String(cellNumber)) }
    private func string(_ value: Any?) throws -> String {
        guard let value else { return "" }
        if let text = value as? String {
            guard text.utf8.count <= 24 * 1_024 * 1_024 else { throw ImportFailure("notebook text value exceeds 24 MiB") }
            return text
        }
        if let lines = value as? [String] {
            guard lines.reduce(0, { $0 + $1.utf8.count }) <= 24 * 1_024 * 1_024 else { throw ImportFailure("notebook text value exceeds 24 MiB") }
            return lines.joined()
        }
        throw ImportFailure("notebook text must be a string or array of strings in cell \(cellNumber)")
    }
    private func traceback(_ value: Any?) throws -> String {
        guard let lines = value as? [String] else { return try string(value) }
        // Quelltextarrays sind Fragmente, Traceback-Einträge dagegen Zeilen.
        // Vorhandene Zeilenenden erhalten, fehlende zwischen Einträgen ergänzen.
        _ = try string(lines)
        return lines.enumerated().map { index, line in
            line + (index < lines.count - 1 && !line.hasSuffix("\n") && !line.hasSuffix("\r") ? "\n" : "")
        }.joined()
    }
    static func fence(_ text: String, language: String) -> String {
        var maximum = 0
        var run = 0
        for character in text { if character == "`" { run += 1; maximum = max(maximum, run) } else { run = 0 } }
        let marker = String(repeating: "`", count: max(3, maximum + 1))
        return marker + language + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + marker
    }
    private func image(_ representations: [String: Any]) throws -> String? {
        let types = representations.keys.filter { $0.hasPrefix("image/") }.sorted { lhs, rhs in
            let priority = ["image/png", "image/jpeg", "image/gif", "image/tiff"]
            return (priority.firstIndex(of: lhs) ?? 100, lhs) < (priority.firstIndex(of: rhs) ?? 100, rhs)
        }
        var result: String?
        for type in types {
            guard result == nil else { continue } // MIME-Alternativen beschreiben dasselbe Bild.
            do {
                let encoded = try string(representations[type])
                guard encoded.utf8.count <= 24 * 1_024 * 1_024,
                      let data = Data(base64Encoded: encoded.filter { !$0.isWhitespace }) else { throw ImportFailure("invalid or oversized Base64 image") }
                result = try media.save(data)
            } catch {
                try ConversionExecution.check()
                warn("imageUnavailable", "\(type) was not copied: \(error.localizedDescription)")
            }
        }
        return result
    }
    private func markdownResources(_ text: String, attachments: [String: String]) throws -> String {
        var result = text
        for (target, path) in attachments.sorted(by: { $0.key < $1.key }) {
            result = MarkdownLinkTargetRewriter.replacing(in: result, from: target, to: path)
        }
        // Nur Kandidaten sammeln. Ob ein Kandidat tatsächlich außerhalb eines
        // Code-/HTML-Containers liegt, entscheidet der bestehende Markdown-Rewriter.
        let targets = try MarkdownLinkTargetRewriter.resourceCandidates(in: result, maximum: 4_096)
        for target in targets.sorted() {
            try ConversionExecution.check()
            guard !media.paths.contains(target), !target.hasPrefix("#") else { continue }
            let probe = MarkdownLinkTargetRewriter.replacing(in: result, from: target, to: "#pmt-resource-check")
            guard probe != result else { continue }
            let scheme = URLComponents(string: target)?.scheme?.lowercased()
            if ["https", "http", "mailto"].contains(scheme ?? "") {
                warn("externalReferenceNotLoaded", "External Markdown reference was retained but never loaded: \(target)")
            } else {
                warn("resourceUnavailable", "A missing local attachment or unsafe Markdown reference was not loaded: \(target)")
                result = MarkdownLinkTargetRewriter.replacing(in: result, from: target, to: "#unavailable-resource")
            }
        }
        if result.range(of: #"<(?:img|script|iframe|object|video|audio)\b"#, options: .regularExpression) != nil {
            warn("htmlNotInterpreted", "Raw HTML is retained as notebook Markdown; embedded resources are not inspected or loaded.")
        }
        return result
    }
}
