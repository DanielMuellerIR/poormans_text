import Foundation

struct MBOXAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors = [SupportedFormat(format: .mbox, fileExtensions: ["mbox"], containerKind: .file, requiredTools: [.pandoc])]
    private static let priority = 185

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let named = inputURL.pathExtension.lowercased() == "mbox"
        do {
            let prefix = try VerifiedFileStaging.prefix(of: inputURL, maximumBytes: MBOXReader.maximumArchiveBytes,
                prefixBytes: MIMEMessage.maximumHeaderBytes + 8192, describedAs: "the MBOX archive")
            if prefix.isEmpty && named { return .match(.init(format: .mbox, priority: Self.priority, expectedWarnings: [])) }
            guard let newline = prefix.firstIndex(of: 10) else {
                if named { throw ImportFailure("the MBOX has no complete separator line") }
                return .noMatch
            }
            var first = Data(prefix[..<newline])
            if first.last == 13 { first.removeLast() }
            guard MBOXReader.isEnvelope(first) else {
                if named { throw ImportFailure("the MBOX does not start with a valid From separator") }
                return .noMatch
            }
            try MBOXReader.validateHeaders(Data(prefix.dropFirst(newline + 1)))
            return .match(.init(format: .mbox, priority: Self.priority, expectedWarnings: []))
        } catch let error as ConversionError { throw error }
        catch { return named ? .invalid(format: .mbox, priority: Self.priority, reason: error.localizedDescription) : .noMatch }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        var writer = CollectionOutputWriter(context: context)
        do {
            try MBOXReader.read(context.resolvedInputURL) { message in
                try ConversionExecution.report(.init(phase: .converting, format: .mbox, unit: .message, completed: message.index - 1))
                let part = try MIMEMessage.read(message.data, emlx: false)
                let metadata = try MailAdapter.metadata(part.headers)
                let table = try MailAdapter.headerTable([.init(name: "mbox-envelope", value: message.envelope)] + part.headers)
                try writer.append(title: metadata.title ?? "Message \(message.index)", metadata: metadata,
                    location: .init(message: String(message.index))) { child in
                    let converted = try MailBodyConverter.convert(part, context: child)
                    try ConversionPostprocessor.prepend(table, to: child.stagedOutputDirectory.appendingPathComponent(converted.markdownRelativePath))
                    var warnings = converted.warnings
                    if message.hasQuotedFrom {
                        warnings.append(.init(code: "mbox.fromQuotingRetained", message: "MBOX From quoting was retained because its original variant cannot be identified reliably.", kind: .approximation))
                    }
                    return .init(markdownRelativePath: converted.markdownRelativePath, assetRelativePaths: converted.assetRelativePaths,
                        warnings: warnings, metadata: metadata)
                }
            }
            try ConversionExecution.report(.init(phase: .converting, format: .mbox, unit: .message,
                completed: writer.documents.count, total: writer.documents.count))
            return try writer.finish(metadata: .init(title: context.inputURL.deletingPathExtension().lastPathComponent))
        } catch let error as ConversionError { throw error }
        catch { throw ConversionError.invalidInput(context.inputURL, format: .mbox, reason: error.localizedDescription) }
    }
}
