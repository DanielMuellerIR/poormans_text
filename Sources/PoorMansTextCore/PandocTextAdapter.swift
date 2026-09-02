import Foundation

/// Formate, die Pandoc liest und die keinen eigenen nativen Leser brauchen:
/// HTML und Webarchive, EPUB sowie die Textformate LaTeX, DocBook, Org,
/// MediaWiki, Textile, reStructuredText und FictionBook.
///
/// Der Weg ist für alle gleich: geprüfte Kopie im Arbeitsordner, Pandoc im
/// Sandbox-Modus nach HTML, Bildverweise über `HTMLImageSourceResolver`
/// bereinigen, dann die gemeinsame HTML-Schlussstrecke. Entfernte Ressourcen
/// werden nie geladen; Pandocs `--sandbox` verhindert zusätzlich, dass etwa
/// `\input{}` in LaTeX fremde Dateien liest.
struct PandocTextAdapter: DocumentConversionAdapter {
    /// Ein Format mit Endungen, Pandoc-Leser und Erkennungsregel.
    struct Kind: Sendable {
        enum Detection: Sendable {
            /// Text mit dieser Endung genügt.
            case textWithExtension
            /// Die Endung UND eine Signatur im Dateikopf (kleingeschrieben).
            case textWithSignature([String])
            /// Die Signatur genügt auch ohne Endung.
            case signatureAlone([String])
            case epub
            case webArchive
        }

        let format: InputFormat
        let extensions: [String]
        let reader: String
        let detection: Detection
        let expectedWarnings: [ConversionWarning]
    }

    static let kinds: [Kind] = [
        Kind(format: .html, extensions: ["html", "htm", "xhtml"], reader: "html",
             detection: .signatureAlone(["<html", "<!doctype html", "<body", "<head"]),
             expectedWarnings: [.htmlStructureSimplified]),
        Kind(format: .webarchive, extensions: ["webarchive"], reader: "html",
             detection: .webArchive, expectedWarnings: [.htmlStructureSimplified]),
        Kind(format: .epub, extensions: ["epub"], reader: "epub",
             detection: .epub, expectedWarnings: [.epubFlattened]),
        Kind(format: .latex, extensions: ["tex", "latex"], reader: "latex",
             detection: .textWithSignature(["\\"]), expectedWarnings: [.latexSimplified]),
        // `.xml` steht bewusst nicht in den Endungen: Die Ordnersuche würde
        // sonst jede XML-Datei einsammeln. Eine `.xml`-Datei mit
        // DocBook-Namensraum wird trotzdem erkannt (siehe `inspectInput`).
        Kind(format: .docbook, extensions: ["dbk", "docbook"], reader: "docbook",
             detection: .textWithSignature(["docbook", "<book", "<article", "<chapter"]),
             expectedWarnings: []),
        Kind(format: .org, extensions: ["org"], reader: "org",
             detection: .textWithExtension, expectedWarnings: []),
        Kind(format: .mediawiki, extensions: ["wiki", "mediawiki"], reader: "mediawiki",
             detection: .textWithExtension, expectedWarnings: []),
        Kind(format: .textile, extensions: ["textile"], reader: "textile",
             detection: .textWithExtension, expectedWarnings: []),
        Kind(format: .rst, extensions: ["rst"], reader: "rst",
             detection: .textWithExtension, expectedWarnings: []),
        Kind(format: .fb2, extensions: ["fb2"], reader: "fb2",
             detection: .textWithSignature(["<fictionbook"]), expectedWarnings: []),
    ]

    var supportedFormatDescriptors: [SupportedFormat] {
        Self.kinds.map {
            SupportedFormat(
                format: $0.format,
                fileExtensions: $0.extensions,
                containerKind: .file,
                requiredTools: [.pandoc]
            )
        }
    }

    private static let detectionPriority = 105
    static let maximumTextBytes = 64 * 1_024 * 1_024
    private static let inspectionBytes = 16_384

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .noMatch
        }
        let fileExtension = inputURL.pathExtension.lowercased()
        let byExtension = Self.kinds.first { $0.extensions.contains(fileExtension) }

        // EPUB ist ein ZIP: der Paketweg entscheidet, nicht der Textkopf.
        if try ZIPArchiveInspector.looksLikeZIP(at: inputURL) {
            guard let epub = Self.kinds.first(where: { $0.format == .epub }) else { return .noMatch }
            do {
                if try Self.isEPUB(at: inputURL) {
                    return .match(AdapterInputInspection(format: .epub, priority: Self.detectionPriority, expectedWarnings: epub.expectedWarnings))
                }
            } catch {
                if byExtension?.format == .epub {
                    return .invalid(format: .epub, priority: Self.detectionPriority, reason: error.localizedDescription)
                }
            }
            return byExtension?.format == .epub
                ? .invalid(format: .epub, priority: Self.detectionPriority, reason: "the file is a ZIP archive but not an EPUB package")
                : .noMatch
        }

        let prefix: Data
        do {
            prefix = try VerifiedFileStaging.prefix(
                of: inputURL,
                maximumBytes: max(Self.maximumTextBytes, WebArchiveReader.maximumSourceBytes),
                prefixBytes: Self.inspectionBytes,
                describedAs: "the text source"
            )
        } catch {
            guard let byExtension else { return .noMatch }
            return .invalid(format: byExtension.format, priority: Self.detectionPriority, reason: error.localizedDescription)
        }

        if let byExtension, case .webArchive = byExtension.detection {
            return WebArchiveReader.looksLikeWebArchive(prefix: prefix)
                ? .match(AdapterInputInspection(format: .webarchive, priority: Self.detectionPriority, expectedWarnings: byExtension.expectedWarnings))
                : .invalid(format: .webarchive, priority: Self.detectionPriority, reason: "the file is not a web archive property list")
        }

        guard !prefix.contains(0) else {
            guard let byExtension else { return .noMatch }
            return .invalid(format: byExtension.format, priority: Self.detectionPriority, reason: "the file contains binary data, not text")
        }
        let head = String(decoding: prefix, as: UTF8.self).lowercased()

        if let byExtension {
            switch byExtension.detection {
            case .textWithExtension:
                return .match(AdapterInputInspection(format: byExtension.format, priority: Self.detectionPriority, expectedWarnings: byExtension.expectedWarnings))
            case .textWithSignature(let signatures), .signatureAlone(let signatures):
                if signatures.contains(where: { head.contains($0) }) || byExtension.format == .html {
                    return .match(AdapterInputInspection(format: byExtension.format, priority: Self.detectionPriority, expectedWarnings: byExtension.expectedWarnings))
                }
                return .invalid(format: byExtension.format, priority: Self.detectionPriority, reason: "the file carries no \(byExtension.format.rawValue) content")
            case .epub, .webArchive:
                return .noMatch
            }
        }

        // Eine `.xml`-Datei ist nur mit DocBook-Namensraum ein DocBook.
        if fileExtension == "xml", head.contains("docbook.org/ns/docbook") || head.contains("docbook xml"),
           let docbook = Self.kinds.first(where: { $0.format == .docbook }) {
            return .match(AdapterInputInspection(format: .docbook, priority: Self.detectionPriority, expectedWarnings: docbook.expectedWarnings))
        }

        // Ohne passende Endung zählt nur eine eindeutige Signatur (HTML).
        for kind in Self.kinds {
            if case .signatureAlone(let signatures) = kind.detection,
               signatures.contains(where: { head.contains($0) }) {
                return .match(AdapterInputInspection(format: kind.format, priority: Self.detectionPriority, expectedWarnings: kind.expectedWarnings))
            }
        }
        return .noMatch
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        guard let kind = Self.kinds.first(where: { $0.format == context.format }) else {
            throw ConversionError.unsupportedInput(context.inputURL)
        }
        let pandocExecutable = try PandocTool.resolve(context.options.pandocExecutable)
        let workDirectory = context.workDirectory
        let sourceDirectory = context.resolvedInputURL.deletingLastPathComponent()
        var warnings = kind.expectedWarnings
        var metadata = DocumentMetadata()

        let html: String
        var baseURL: URL?
        var subresources = [String: HTMLImageSourceResolver.Subresource]()
        var baseDirectory: URL? = sourceDirectory

        switch kind.detection {
        case .webArchive:
            let staged = try Self.stageFile(context, named: "verified-source.webarchive", maximumBytes: WebArchiveReader.maximumSourceBytes)
            let archive: WebArchiveReader.Archive
            do {
                archive = try WebArchiveReader.read(try Data(contentsOf: staged, options: [.mappedIfSafe]))
            } catch {
                throw ConversionError.invalidInput(context.inputURL, format: context.format, reason: error.localizedDescription)
            }
            html = archive.html
            baseURL = archive.baseURL
            subresources = archive.subresources
            baseDirectory = nil
            if archive.assumedEncoding {
                warnings.append(.textEncodingAssumed)
            }
            metadata = Self.htmlMetadata(in: html)

        case .signatureAlone where context.format == .html:
            let staged = try Self.stageFile(context, named: "verified-source.html", maximumBytes: Self.maximumTextBytes)
            let data = (try? Data(contentsOf: staged, options: [.mappedIfSafe])) ?? Data()
            if let text = String(data: data, encoding: .utf8) {
                html = text
            } else if let text = String(data: data, encoding: .windowsCP1252) {
                html = text
                warnings.append(.textEncodingAssumed)
            } else {
                throw ConversionError.invalidInput(context.inputURL, format: context.format, reason: "the HTML could not be decoded as text")
            }
            metadata = Self.htmlMetadata(in: html)

        case .epub:
            let staged: URL
            do {
                staged = try ZIPArchiveInspector.stageVerifiedPackage(from: context.resolvedInputURL, into: workDirectory, named: "verified-source.epub")
                guard try Self.isEPUB(at: staged) else {
                    throw WebArchiveReader.WebArchiveError("the verified EPUB package changed after inspection")
                }
            } catch let error as ConversionError {
                throw error
            } catch {
                throw ConversionError.invalidInput(context.inputURL, format: context.format, reason: error.localizedDescription)
            }
            html = try Self.pandocHTML(from: staged, reader: kind.reader, context: context, pandocExecutable: pandocExecutable)
            baseDirectory = nil

        default:
            let staged = try Self.stageFile(context, named: "verified-source.\(context.inputURL.pathExtension.lowercased())", maximumBytes: Self.maximumTextBytes)
            guard let data = try? Data(contentsOf: staged, options: [.mappedIfSafe]), String(data: data, encoding: .utf8) != nil else {
                throw ConversionError.invalidInput(context.inputURL, format: context.format, reason: "the file is not valid UTF-8 text")
            }
            html = try Self.pandocHTML(from: staged, reader: kind.reader, context: context, pandocExecutable: pandocExecutable)
        }

        let resolution = try HTMLImageSourceResolver.resolve(
            html: html,
            baseDirectory: baseDirectory,
            baseURL: baseURL,
            subresources: subresources,
            workDirectory: workDirectory
        )
        if resolution.remoteImagesKeptAsLinks > 0 {
            warnings.append(.remoteImagesKeptAsLinks(resolution.remoteImagesKeptAsLinks))
        }
        if resolution.missingImagesDropped > 0 {
            warnings.append(.missingImagesDropped(resolution.missingImagesDropped))
        }

        let converted = try HTMLDocumentConverter.convert(
            html: resolution.html,
            inputURL: context.inputURL,
            format: context.format,
            resourceDirectory: workDirectory,
            stagedOutputDirectory: context.stagedOutputDirectory,
            pandocExecutable: pandocExecutable
        )
        return StagedConversionResult(
            markdownRelativePath: converted.markdownRelativePath,
            assetRelativePaths: converted.assetRelativePaths,
            warnings: warnings,
            metadata: metadata
        )
    }

    // MARK: - Hilfsfunktionen

    private static func stageFile(_ context: AdapterConversionContext, named name: String, maximumBytes: Int) throws -> URL {
        let staged = context.workDirectory.appendingPathComponent(name)
        do {
            try VerifiedFileStaging.stage(
                from: context.resolvedInputURL,
                to: staged,
                maximumBytes: maximumBytes,
                describedAs: "the \(context.format.rawValue) source"
            )
        } catch let error as VerifiedFileStaging.StagingError where error.kind == .source {
            throw ConversionError.invalidInput(context.inputURL, format: context.format, reason: error.reason)
        } catch let error as VerifiedFileStaging.StagingError {
            throw ConversionError.fileSystemFailure(error.reason)
        }
        return staged
    }

    static func isEPUB(at url: URL) throws -> Bool {
        let package = try ZIPArchiveInspector.packageContents(at: url, entryNames: ["mimetype"])
        guard let mimetype = package.entries["mimetype"] else {
            return false
        }
        return String(decoding: mimetype, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip"
    }

    /// Pandoc liest die Quelle im Sandbox-Modus und schreibt HTML in den
    /// Arbeitsordner; eingebettete Medien (EPUB, FB2) landen daneben.
    private static func pandocHTML(from source: URL, reader: String, context: AdapterConversionContext, pandocExecutable: URL) throws -> String {
        let htmlURL = context.workDirectory.appendingPathComponent("document.html")
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                executable: pandocExecutable,
                arguments: [
                    "--sandbox",
                    "--from=\(reader)",
                    "--to=html5",
                    "--extract-media=.",
                    "--wrap=preserve",
                    "--output", htmlURL.path,
                    source.path,
                ],
                currentDirectory: context.workDirectory
            )
        } catch {
            throw ConversionError.pandocFailed(status: -1, message: error.localizedDescription)
        }
        guard result.status == 0 else {
            throw ConversionError.pandocFailed(status: result.status, message: result.standardError)
        }
        do {
            return try String(contentsOf: htmlURL, encoding: .utf8)
        } catch {
            throw ConversionError.fileSystemFailure("conversion produced no readable HTML: \(error.localizedDescription)")
        }
    }

    /// `<title>` und `<meta name="author">` aus dem HTML-Kopf.
    static func htmlMetadata(in html: String) -> DocumentMetadata {
        func first(_ pattern: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = expression.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)),
                  match.numberOfRanges > 1 else {
                return nil
            }
            let value = (html as NSString).substring(with: match.range(at: 1))
            return value
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        return DocumentMetadata(
            title: first(#"<title[^>]*>(.*?)</title>"#),
            author: first(#"<meta\s+[^>]*name\s*=\s*["']author["'][^>]*content\s*=\s*["']([^"']*)["']"#)
                ?? first(#"<meta\s+[^>]*content\s*=\s*["']([^"']*)["'][^>]*name\s*=\s*["']author["']"#),
            description: first(#"<meta\s+[^>]*name\s*=\s*["']description["'][^>]*content\s*=\s*["']([^"']*)["']"#)
        )
    }
}
