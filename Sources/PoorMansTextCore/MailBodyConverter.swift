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
        let html = try selection.bodies.map { body in
            if body.isHTML {
                let flattened = try flattenTables(body.text)
                if flattened.changed, !warnings.contains(where: { $0.code == "mail.tablesFlattened" }) {
                    warnings.append(ConversionWarning(code: "mail.tablesFlattened",
                        message: "HTML tables in the mail body were rendered as text blocks in cell order; table layout was not preserved."))
                }
                return flattened.html
            }
            let normalized = body.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            return "<p>" + escapedHTML(normalized).replacingOccurrences(of: "\n", with: "<br>\n") + "</p>"
        }.joined(separator: "\n<hr>\n")
        let resolution = try HTMLImageSourceResolver.resolve(html: html, baseDirectory: resourceDirectory, baseURL: nil,
                                                             subresources: resources, workDirectory: context.workDirectory)
        if selection.bodies.contains(where: \.isHTML) { warnings.append(.htmlStructureSimplified) }
        if resolution.remoteImagesKeptAsLinks > 0 { warnings.append(.remoteImagesKeptAsLinks(resolution.remoteImagesKeptAsLinks)) }
        if resolution.missingImagesDropped > 0 { warnings.append(.missingImagesDropped(resolution.missingImagesDropped)) }
        let converted = try HTMLDocumentConverter.convert(html: resolution.html, inputURL: context.inputURL,
            format: context.format, resourceDirectory: context.workDirectory,
            stagedOutputDirectory: context.stagedOutputDirectory,
            pandocExecutable: PandocTool.resolve(context.options.pandocExecutable))
        let attachments = try MailContent.stageAttachments(selection.attachments, in: context.stagedOutputDirectory)
        if !attachments.isEmpty {
            let url = context.stagedOutputDirectory.appendingPathComponent(converted.markdownRelativePath)
            do {
                var markdown = try String(contentsOf: url, encoding: .utf8)
                markdown += "\n\n## Attachments\n\n"
                for attachment in attachments {
                    markdown += "- [" + MarkdownEscaping.inlineLiteral(attachment.displayName) + "](" + attachment.relativePath + ")\n"
                }
                try Data(markdown.utf8).write(to: url, options: .atomic)
            } catch { throw ConversionError.fileSystemFailure(error.localizedDescription) }
        }
        return StagedConversionResult(markdownRelativePath: converted.markdownRelativePath,
            assetRelativePaths: converted.assetRelativePaths + attachments.map(\.relativePath), warnings: warnings)
    }

    private static func escapedHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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
