#if os(Linux)
import Foundation

/// Word-DOC wird nur aus einer verifizierten OLE-Arbeitskopie gelesen.
struct LinuxLegacyWordAdapter: DocumentConversionAdapter {
    private static let maximumSourceBytes = 1_073_741_824
    private static let maximumHTMLBytes = 128 * 1024 * 1024
    private static let maximumReferenceBytes = 64 * 1024 * 1024
    private static let maximumComparedTokens = 500_000
    private static let maximumTokenBytes = 4096
    let supportedFormatDescriptors = [PlatformFormatDescriptors.doc]

    static func isPythonUNOAvailable() -> Bool {
        (try? LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let result = try LinuxBackendResources.runPython(script: "legacy_doc",
                arguments: ["--capabilities"], in: directory, timeout: 10)
            return result.status == 0
        }) == true
    }

    func unavailableReason(for format: InputFormat) -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/libreoffice") else {
            return PlatformBackendUnavailable("LibreOffice DOC").localizedDescription
        }
        return Self.isPythonUNOAvailable() ? nil : PlatformBackendUnavailable("Python UNO DOC").localizedDescription
    }

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
            guard receipt.loadMacroExecutionMode == 0, receipt.loadUpdateDocMode == 0,
                  receipt.sourceByteCount == sourceIdentity.byteCount,
                  receipt.sourceSHA256 == sourceIdentity.sha256,
                  receipt.htmlFile.hasPrefix("html/"), !receipt.htmlFile.contains(".."),
                  !receipt.htmlFile.dropFirst(5).contains("/"), receipt.referenceFile == "reference.txt",
                  (0...4096).contains(receipt.imageReferenceCount), (0...4096).contains(receipt.imageResourceCount) else {
                throw ConversionError.fileSystemFailure("the local DOC export returned an invalid receipt")
            }
            let htmlDirectory = directory.appendingPathComponent("html", isDirectory: true)
            let html = try Self.boundedText(at: directory.appendingPathComponent(receipt.htmlFile),
                maximumBytes: Self.maximumHTMLBytes, subject: "the DOC HTML export")
            let reference = try Self.boundedText(at: directory.appendingPathComponent(receipt.referenceFile),
                maximumBytes: Self.maximumReferenceBytes, subject: "the DOC text export")
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversionError.invalidInput(context.inputURL, format: .doc, reason: "LibreOffice produced empty HTML")
            }
            let resources = try HTMLImageSourceResolver.resolve(html: html, baseDirectory: htmlDirectory,
                baseURL: nil, subresources: [:], workDirectory: htmlDirectory)
            let converted = try HTMLDocumentConverter.convert(html: resources.html, inputURL: context.inputURL,
                format: .doc, resourceDirectory: htmlDirectory,
                stagedOutputDirectory: context.stagedOutputDirectory, pandocExecutable: pandoc)
            let markdown = try Self.boundedText(at: context.stagedOutputDirectory.appendingPathComponent(converted.markdownRelativePath),
                maximumBytes: Self.maximumHTMLBytes, subject: "the DOC Markdown export")
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

    private static func boundedText(at url: URL, maximumBytes: Int, subject: String) throws -> String {
        do {
            let bytes = try VerifiedFileStaging.withVerifiedSource(at: url, maximumBytes: maximumBytes,
                describedAs: subject, followSourceSymlink: false) { file, size in
                var data = Data()
                data.reserveCapacity(Int(size))
                _ = try file.readChunks(maximumBytes: maximumBytes, chunkSize: 262_144,
                    budgetExceeded: { ConversionError.fileSystemFailure("\(subject) exceeds its byte budget") }) { chunk in
                    data.append(contentsOf: chunk)
                    return true
                }
                return data
            }
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw ConversionError.fileSystemFailure("\(subject) is not valid UTF-8")
            }
            return text
        } catch let error as ConversionError { throw error }
        catch { throw ConversionError.fileSystemFailure(error.localizedDescription) }
    }

    private static func wordCounts(_ text: String, inputURL: URL) throws -> (counts: [String: Int], total: Int) {
        var counts: [String: Int] = [:]
        var word = "", wordBytes = 0, total = 0, scanned = 0
        func flush() throws {
            guard !word.isEmpty else { return }
            guard total < maximumComparedTokens else {
                throw ConversionError.invalidInput(inputURL, format: .doc,
                    reason: "the DOC text comparison exceeds its \(maximumComparedTokens)-token budget")
            }
            total += 1
            counts[word.lowercased(), default: 0] += 1
            word.removeAll(keepingCapacity: true)
            wordBytes = 0
        }
        // Vor dem Aufbau der Wörterbuchschlüssel zählen; split/map würde schon
        // bei der Budgetprüfung Millionen Substrings beziehungsweise Strings erzeugen.
        for character in text {
            scanned += 1
            if scanned % 4096 == 0 { try ConversionExecution.check() }
            if character.isLetter || character.isNumber {
                let bytes = character.utf8.count
                guard bytes <= maximumTokenBytes - wordBytes else {
                    throw ConversionError.invalidInput(inputURL, format: .doc,
                        reason: "a DOC comparison token exceeds its \(maximumTokenBytes)-byte budget")
                }
                word.append(character)
                wordBytes += bytes
            } else { try flush() }
        }
        try flush()
        return (counts, total)
    }

    static func textDiagnostic(reference: String, markdown: String, inputURL: URL) throws -> ConversionWarning? {
        let source = try wordCounts(reference, inputURL: inputURL)
        guard source.total > 0 else { return nil }
        let available = try wordCounts(markdown, inputURL: inputURL)
        let retained = source.counts.reduce(0) { $0 + min($1.value, available.counts[$1.key, default: 0]) }
        guard retained >= max(1, source.total * 4 / 5) else {
            throw ConversionError.invalidInput(inputURL, format: .doc,
                reason: "the generated Markdown contains substantially less text than LibreOffice extracted")
        }
        guard retained < source.total else { return nil }
        return .init(code: "legacyWord.textContentLoss",
            message: "\(source.total - retained) of \(source.total) independently exported DOC text words were not represented in Markdown.", kind: .contentLoss)
    }

    private struct ExportReceipt: Decodable {
        let loadMacroExecutionMode: Int
        let loadUpdateDocMode: Int
        let htmlFile: String
        let referenceFile: String
        let sourceSHA256: String
        let sourceByteCount: Int
        let imageReferenceCount: Int
        let imageResourceCount: Int
    }
}
#endif
