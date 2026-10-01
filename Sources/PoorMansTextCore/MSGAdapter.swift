import Foundation

struct MSGAdapter: DocumentConversionAdapter {
    var supportedFormatDescriptors: [SupportedFormat] {
        [.init(format: .msg, fileExtensions: ["msg"], containerKind: .file, requiredTools: [.pandoc])]
    }

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let named = inputURL.pathExtension.lowercased() == "msg"
        do {
            let prefix = try VerifiedFileStaging.prefix(of: inputURL, maximumBytes: MIMEMessage.maximumSourceBytes,
                                                       prefixBytes: 8, describedAs: "the MSG source")
            guard OLECompoundDocument.hasSignature(prefix) else {
                return named ? .invalid(format: .msg, priority: 180, reason: "the MSG OLE signature is missing") : .noMatch
            }
            let bytes = try VerifiedFileStaging.contents(of: inputURL, maximumBytes: MIMEMessage.maximumSourceBytes, describedAs: "the MSG source")
            let tree = try OLECompoundDocument(data: bytes).storageTree()
            guard try tree.stream(at: ["__properties_version1.0"]) != nil else {
                return named ? .invalid(format: .msg, priority: 180, reason: "the MSG property stream is missing") : .noMatch
            }
            let props = try MSGMessage.properties(tree, storage: [], kind: .root)
            let encoding = try MSGMessage.codepage(props.integer(0x3FFD) ?? props.integer(0x3FDE) ?? 1252)
            guard let messageClass = try MSGMessage.stringValue(0x001A, properties: props, tree: tree, storage: [], encoding: encoding),
                  messageClass.uppercased().hasPrefix("IPM.NOTE"), !messageClass.uppercased().contains("SMIME") else {
                return .invalid(format: .msg, priority: 180, reason: "the MSG is not a supported unencrypted mail message")
            }
            return .match(.init(format: .msg, priority: 180, expectedWarnings: []))
        } catch {
            return named ? .invalid(format: .msg, priority: 180, reason: error.localizedDescription) : .noMatch
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        do {
            let bytes = try VerifiedFileStaging.contents(of: context.resolvedInputURL,
                maximumBytes: MIMEMessage.maximumSourceBytes, describedAs: "the MSG source")
            let message = try MSGMessage.read(bytes)
            var resources: URL?
            let body: MailContent.Body
            switch message.body {
            case .text(let text): body = .init(text: text, isHTML: false)
            case .html(let html): body = .init(text: html, isHTML: true)
            case .rtf(let rtf):
                let directory = context.workDirectory.appendingPathComponent("rtf-body", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let source = directory.appendingPathComponent("body.rtf")
                let htmlURL = directory.appendingPathComponent("body.html")
                try rtf.write(to: source, options: .withoutOverwriting)
                let result = try ProcessRunner.run(executable: PandocTool.resolve(context.options.pandocExecutable),
                    arguments: ["--sandbox", "--from=rtf", "--to=html5", "--extract-media=.", "--wrap=preserve",
                                "--output", htmlURL.path, source.path], currentDirectory: directory)
                guard result.status == 0 else { throw ConversionError.pandocFailed(status: result.status, message: result.standardError) }
                let html = try VerifiedFileStaging.contents(of: htmlURL, maximumBytes: MIMEMessage.maximumSourceBytes,
                                                          describedAs: "the converted MSG RTF body")
                guard let text = String(data: html, encoding: .utf8) else { throw MSGProperties.Failure(reason: "the MSG RTF HTML output is not UTF-8") }
                body = .init(text: text, isHTML: true)
                resources = directory
            }
            let selection = MailContent.Selection(bodies: [body], attachments: message.attachments)
            let result = try MailBodyConverter.convert(selection, context: context, resourceDirectory: resources)
            let table = try MailAdapter.headerTable(message.headers)
            try ConversionPostprocessor.prepend(table, to: context.stagedOutputDirectory.appendingPathComponent(result.markdownRelativePath))
            var metadata = try MailAdapter.metadata(message.headers)
            if metadata.created == nil { metadata.created = message.created }
            return .init(markdownRelativePath: result.markdownRelativePath, assetRelativePaths: result.assetRelativePaths,
                         warnings: result.warnings, metadata: metadata)
        } catch let error as ConversionError { throw error }
        catch { throw ConversionError.invalidInput(context.inputURL, format: .msg, reason: error.localizedDescription) }
    }
}
