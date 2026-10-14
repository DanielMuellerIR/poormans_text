import Foundation

/// Nutzt für Mailkörper dieselbe HTML- und Asset-Schlussstrecke wie andere Dokumente.
enum MailBodyConverter {
    static func convert(_ part: MIMEMessage.Part, context: AdapterConversionContext) throws -> StagedConversionResult {
        try convert(MailContent.select(part), context: context)
    }

    static func convert(_ selection: MailContent.Selection, context: AdapterConversionContext,
                        resourceDirectory: URL? = nil) throws -> StagedConversionResult {
        let resources = try MailContent.subresources(selection.attachments)
        var warnings = selection.warnings
        var bodies = [String]()
        var assets = [String]()
        var remoteImages = 0
        var missingImages = 0
        let imageBudget = HTMLImageSourceResolver.ImageBudget()
        let markdownName = context.inputURL.deletingPathExtension().lastPathComponent + ".md"
        // Jeder MIME-Körper hat eine eigene HTML-Lesersicht. Offene Tags,
        // Kommentare oder Listen dürfen keinen späteren Körper einfangen.
        for body in selection.bodies {
            try ConversionExecution.check()
            guard body.isHTML else {
                let normalized = body.text.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                bodies.append(try literalBody(normalized))
                continue
            }
            let flattened = try flattenTables(body.text)
            if flattened.changed, !warnings.contains(where: { $0.code == "mail.tablesFlattened" }) {
                warnings.append(ConversionWarning(code: "mail.tablesFlattened",
                    message: "HTML tables in the mail body were rendered as text blocks in cell order; table layout was not preserved."))
            }
            let partDirectory = context.workDirectory.appendingPathComponent("mail-body-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: partDirectory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: partDirectory) }
            let resolution = try HTMLImageSourceResolver.resolve(html: flattened.html, baseDirectory: resourceDirectory,
                baseURL: nil, subresources: resources, workDirectory: partDirectory, imageBudget: imageBudget)
            remoteImages += resolution.remoteImagesKeptAsLinks
            missingImages += resolution.missingImagesDropped
            let converted = try HTMLDocumentConverter.convert(html: resolution.html, inputURL: context.inputURL,
                format: context.format, resourceDirectory: partDirectory, stagedOutputDirectory: partDirectory,
                pandocExecutable: PandocTool.resolve(context.options.pandocExecutable))
            var markdown = try String(contentsOf: partDirectory.appendingPathComponent(converted.markdownRelativePath), encoding: .utf8)
            var mapping = [String: String]()
            for path in converted.assetRelativePaths {
                let source = partDirectory.appendingPathComponent(path)
                let name = String(format: "image%02d", assets.count + 1) + "." + source.pathExtension
                let target = "images/" + name
                let directory = context.stagedOutputDirectory.appendingPathComponent("images")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: context.stagedOutputDirectory.appendingPathComponent(target))
                mapping[path] = target
                assets.append(target)
            }
            markdown = try MarkdownLinkTargetRewriter.replacing(in: markdown, mapping: mapping,
                checking: ConversionExecution.check)
            bodies.append(markdown)
        }
        if selection.bodies.contains(where: \.isHTML) { warnings.append(.htmlStructureSimplified) }
        if remoteImages > 0 { warnings.append(.remoteImagesKeptAsLinks(remoteImages)) }
        if missingImages > 0 { warnings.append(.missingImagesDropped(missingImages)) }
        do {
            try Data((bodies.joined(separator: "\n\n---\n\n") + "\n").utf8)
                .write(to: context.stagedOutputDirectory.appendingPathComponent(markdownName), options: .atomic)
        } catch { throw ConversionError.fileSystemFailure(error.localizedDescription) }
        let attachments = try MailContent.stageAttachments(selection.attachments, in: context.stagedOutputDirectory)
        if !attachments.isEmpty {
            let url = context.stagedOutputDirectory.appendingPathComponent(markdownName)
            do {
                var markdown = try String(contentsOf: url, encoding: .utf8)
                markdown += "\n\n## Attachments\n\n"
                for attachment in attachments {
                    markdown += "- [" + MarkdownEscaping.inlineLiteral(attachment.displayName) + "](" + attachment.relativePath + ")\n"
                }
                try Data(markdown.utf8).write(to: url, options: .atomic)
            } catch { throw ConversionError.fileSystemFailure(error.localizedDescription) }
        }
        return StagedConversionResult(markdownRelativePath: markdownName,
            assetRelativePaths: assets + attachments.map(\.relativePath), warnings: warnings)
    }

    private static func literalBody(_ text: String) throws -> String {
        var longestRun = 0
        var run = 0
        for (index, byte) in text.utf8.enumerated() {
            if index % 4096 == 0 { try ConversionExecution.check() }
            if byte == 96 {
                run += 1
                longestRun = max(longestRun, run)
            } else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        // Der Leser entfernt genau den Umbruch vor dem Abschluss. Ein bereits
        // vorhandener letzter Umbruch gehört zum Mailkörper und bleibt erhalten.
        return fence + "text\n" + text + "\n" + fence
    }

    private static func flattenTables(_ html: String) throws -> (html: String, changed: Bool) {
        // Mail-Layouts enthalten verschachtelte Tabellen. Pandoc schreibt sie als raw HTML,
        // das der sichere GFM-Weg verwirft; die Zellen müssen vorher zu Textblöcken werden.
        let bytes = Array(html.utf8)
        let names: Set<String> = ["table", "tbody", "thead", "tfoot", "tr", "td", "th"]
        var output = Data()
        var cursor = 0
        var position = 0
        var changed = false
        while position < bytes.count {
            try ConversionExecution.check()
            guard bytes[position] == 60 else { position += 1; continue }
            let start = position
            let comment = bytes[start..<min(start + 4, bytes.count)].elementsEqual([60, 33, 45, 45])
            if comment {
                position += 4
                while position + 2 < bytes.count, !bytes[position...position + 2].elementsEqual([45, 45, 62]) {
                    if position % 4096 == 0 { try ConversionExecution.check() }
                    position += 1
                }
                position = min(position + 3, bytes.count)
                continue
            }
            var nameStart = start + 1
            let closing = nameStart < bytes.count && bytes[nameStart] == 47
            if closing { nameStart += 1 }
            var nameEnd = nameStart
            while nameEnd < bytes.count, (65...90).contains(bytes[nameEnd]) || (97...122).contains(bytes[nameEnd]) {
                nameEnd += 1
            }
            guard nameEnd > nameStart else { position += 1; continue }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self).lowercased()
            var quote: UInt8?
            position = nameEnd
            while position < bytes.count {
                if position % 4096 == 0 { try ConversionExecution.check() }
                let byte = bytes[position]
                if let active = quote {
                    if byte == active { quote = nil }
                } else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                position += 1
            }
            guard position < bytes.count else { break }
            position += 1
            let delimiter = nameEnd < bytes.count ? bytes[nameEnd] : 0
            if names.contains(name), [9, 10, 13, 32, 47, 62].contains(delimiter) {
                output.append(contentsOf: bytes[cursor..<start])
                output.append(contentsOf: (closing ? "</div>" : "<div>").utf8)
                cursor = position
                changed = true
            }
        }
        output.append(contentsOf: bytes[cursor...])
        return (String(decoding: output, as: UTF8.self), changed)
    }
}
