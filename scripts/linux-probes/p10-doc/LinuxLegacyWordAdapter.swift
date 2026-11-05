#if os(Linux)
import Foundation

/// Word-DOC wird nur aus einer verifizierten OLE-Arbeitskopie gelesen.
struct LinuxLegacyWordAdapter: DocumentConversionAdapter {
    private static let maximumSourceBytes = 1_073_741_824
    let supportedFormatDescriptors = [SupportedFormat(format: .doc, fileExtensions: ["doc"],
        containerKind: .file, requiredTools: [.init(rawValue: "libreoffice"), .init(rawValue: "python3"),
                                             .pandoc, .bubblewrap, .processGuard])]

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let expected = inputURL.pathExtension.lowercased() == "doc"
        do {
            let prefix = try VerifiedFileStaging.prefix(of: inputURL.resolvingSymlinksInPath(),
                maximumBytes: Self.maximumSourceBytes, prefixBytes: 8, describedAs: "the DOC source")
            guard OLECompoundDocument.hasSignature(prefix) else {
                return expected ? .invalid(format: .doc, priority: 105,
                    reason: "the OLE compound-document signature is missing") : .noMatch
            }
            let word = try VerifiedFileStaging.withTemporaryCopy(of: inputURL.resolvingSymlinksInPath(),
                maximumBytes: Self.maximumSourceBytes, describedAs: "the DOC source", fileExtension: "doc") { snapshot in
                try Self.hasWordStream(at: snapshot)
            }
            guard word else {
                return expected ? .invalid(format: .doc, priority: 105,
                    reason: "the compound document has no WordDocument stream") : .noMatch
            }
            return .match(.init(format: .doc, priority: 105, expectedWarnings: [.legacyWordPotentialLoss]))
        } catch {
            try ConversionExecution.check()
            return expected ? .invalid(format: .doc, priority: 105, reason: error.localizedDescription) : .noMatch
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        let snapshot = context.workDirectory.appendingPathComponent("verified-source.doc")
        return try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            do {
                try VerifiedFileStaging.stage(from: context.resolvedInputURL, to: snapshot,
                    maximumBytes: Self.maximumSourceBytes, describedAs: "the DOC source")
            } catch let error as VerifiedFileStaging.StagingError where error.kind == .source {
                throw ConversionError.invalidInput(context.inputURL, format: .doc, reason: error.reason)
            } catch {
                throw ConversionError.fileSystemFailure(error.localizedDescription)
            }
            guard try Self.hasWordStream(at: snapshot) else {
                throw ConversionError.invalidInput(context.inputURL, format: .doc,
                    reason: "the DOC source changed after inspection")
            }
            let sourceIdentity = try ConversionFileFingerprint.read(snapshot)
            let pandoc = try PandocTool.resolve(context.options.pandocExecutable)
            let export = try LinuxBackendResources.runPython(script: "legacy_doc", arguments: [snapshot.path],
                in: directory, readOnlyPaths: [snapshot], timeout: ConversionExecution.current?.processTimeout ?? 30)
            if export.status == 69 { throw PlatformBackendUnavailable("LibreOffice DOC converter") }
            if export.status == 124 { throw ConversionError.processTimedOut }
            if export.status == 74 { throw ConversionError.fileSystemFailure(export.standardError) }
            guard export.status == 0 else {
                try ConversionExecution.check()
                throw ConversionError.invalidInput(context.inputURL, format: .doc,
                    reason: export.standardError.isEmpty ? "the local LibreOffice DOC export failed" : export.standardError)
            }
            let receipt = try JSONDecoder().decode(ExportReceipt.self, from: Data(export.standardOutput.utf8))
            guard receipt.sourceByteCount == sourceIdentity.byteCount,
                  receipt.sourceSHA256 == sourceIdentity.sha256,
                  receipt.htmlFile.hasPrefix("html/"), !receipt.htmlFile.contains(".."),
                  !receipt.htmlFile.dropFirst(5).contains("/"), receipt.referenceFile == "reference.txt",
                  (0...4096).contains(receipt.imageReferenceCount), (0...4096).contains(receipt.imageResourceCount) else {
                throw ConversionError.fileSystemFailure("the local DOC export returned an invalid receipt")
            }
            let htmlDirectory = directory.appendingPathComponent("html", isDirectory: true)
            let html = try String(contentsOf: directory.appendingPathComponent(receipt.htmlFile), encoding: .utf8)
            let reference = try String(contentsOf: directory.appendingPathComponent(receipt.referenceFile), encoding: .utf8)
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversionError.invalidInput(context.inputURL, format: .doc, reason: "LibreOffice produced empty HTML")
            }
            let resources = try HTMLImageSourceResolver.resolve(html: html, baseDirectory: htmlDirectory,
                baseURL: nil, subresources: [:], workDirectory: htmlDirectory)
            let converted = try HTMLDocumentConverter.convert(html: resources.html, inputURL: context.inputURL,
                format: .doc, resourceDirectory: htmlDirectory,
                stagedOutputDirectory: context.stagedOutputDirectory, pandocExecutable: pandoc)
            let markdown = try String(contentsOf: context.stagedOutputDirectory.appendingPathComponent(converted.markdownRelativePath), encoding: .utf8)
            var diagnostics = [ConversionWarning.legacyWordPotentialLoss]
            if let warning = try Self.textDiagnostic(reference: reference, markdown: markdown, inputURL: context.inputURL) {
                diagnostics.append(warning)
            }
            if resources.remoteImagesKeptAsLinks > 0 { diagnostics.append(.remoteImagesKeptAsLinks(resources.remoteImagesKeptAsLinks)) }
            if resources.missingImagesDropped > 0 { diagnostics.append(.missingImagesDropped(resources.missingImagesDropped)) }
            if receipt.imageResourceCount > converted.assetRelativePaths.count {
                diagnostics.append(.init(code: "legacyWord.assetsNotRepresented",
                    message: "\(receipt.imageResourceCount - converted.assetRelativePaths.count) generated DOC image resource(s) were not represented in Markdown.", kind: .contentLoss))
            }
            return .init(markdownRelativePath: converted.markdownRelativePath,
                         assetRelativePaths: converted.assetRelativePaths, warnings: diagnostics)
        }
    }

    private static func hasWordStream(at snapshot: URL) throws -> Bool {
        let data = try Data(contentsOf: snapshot, options: [.mappedIfSafe])
        guard OLECompoundDocument.hasSignature(data), let container = try? OLECompoundDocument(data: data) else { return false }
        return try container.storageTree().streamNames(in: []).contains {
            $0.caseInsensitiveCompare("WordDocument") == .orderedSame
        }
    }

    static func textDiagnostic(reference: String, markdown: String, inputURL: URL) throws -> ConversionWarning? {
        let words = reference.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return nil }
        var available = Dictionary(markdown.lowercased().split { !$0.isLetter && !$0.isNumber }.map { (String($0), 1) }, uniquingKeysWith: +)
        var retained = 0
        for word in words {
            let key = String(word)
            if let count = available[key], count > 0 { retained += 1; available[key] = count - 1 }
        }
        guard retained >= max(1, words.count * 4 / 5) else {
            throw ConversionError.invalidInput(inputURL, format: .doc,
                reason: "the generated Markdown contains substantially less text than LibreOffice extracted")
        }
        guard retained < words.count else { return nil }
        return .init(code: "legacyWord.textContentLoss",
            message: "\(words.count - retained) of \(words.count) independently exported DOC text words were not represented in Markdown.", kind: .contentLoss)
    }

    private struct ExportReceipt: Decodable {
        let htmlFile: String
        let referenceFile: String
        let sourceSHA256: String
        let sourceByteCount: Int
        let imageReferenceCount: Int
        let imageResourceCount: Int
    }
}
#endif
