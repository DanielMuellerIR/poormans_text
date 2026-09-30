import Foundation

/// Nutzt für Mailkörper dieselbe HTML- und Asset-Schlussstrecke wie andere Dokumente.
enum MailBodyConverter {
    static func convert(_ part: MIMEMessage.Part, context: AdapterConversionContext) throws -> StagedConversionResult {
        let selection = try MailContent.select(part)
        let resources = try MailContent.subresources(selection.attachments)
        var warnings = selection.warnings
        let html = selection.bodies.map { body in
            if body.isHTML { return body.text }
            let normalized = body.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            return "<p>" + escapedHTML(normalized).replacingOccurrences(of: "\n", with: "<br>\n") + "</p>"
        }.joined(separator: "\n<hr>\n")
        let resolution = try HTMLImageSourceResolver.resolve(html: html, baseDirectory: nil, baseURL: nil,
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
}
