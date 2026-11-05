#if os(Linux)
import Foundation
import CPMTLinux

/// Poppler läuft als eigener lokaler Prozess im PID-/Netzwerk-Namespace.
/// Der Swift-Kern bindet weder Poppler noch einen zweiten PDF-Parser ein.
struct LinuxPDFAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors = [PlatformFormatDescriptors.pdf]

    func unavailableReason(for format: InputFormat) -> String? {
        (try? LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let result = try LinuxBackendResources.runPython(script: "poppler", arguments: ["capabilities"], in: directory)
            return result.status == 0
        }) == true ? nil : PlatformBackendUnavailable("Python GI Poppler/Cairo PDF").localizedDescription
    }

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let expected = inputURL.pathExtension.lowercased() == "pdf"
        do {
            let prefix = try VerifiedFileStaging.prefix(of: inputURL.resolvingSymlinksInPath(), maximumBytes: 1_073_741_824,
                prefixBytes: 1024, describedAs: "the PDF source")
            guard prefix.range(of: Data("%PDF-".utf8)) != nil else {
                return expected ? .invalid(format: .pdf, priority: 107, reason: "the PDF signature is missing") : .noMatch
            }
            _ = try inspectContents(at: inputURL, maximumPages: 1)
            return .match(AdapterInputInspection(format: .pdf, priority: 107, expectedWarnings: [.pdfLayoutNotPreserved]))
        } catch {
            try ConversionExecution.check()
            if case ConversionError.processTimedOut = error { throw error }
            if case ConversionError.fileSystemFailure = error { throw error }
            let reason: String
            if case let ConversionError.invalidInput(_, _, detail) = error { reason = detail }
            else { reason = error.localizedDescription }
            return expected ? .invalid(format: .pdf, priority: 107, reason: reason) : .noMatch
        }
    }

    func inspectContents(at inputURL: URL, maximumPages: Int) throws -> PDFContentSummary {
        guard (1...PDFContentSummary.maximumSummaryPages).contains(maximumPages) else {
            throw ConversionError.invalidInput(inputURL, format: .pdf, reason: "the PDF overview limit is outside its supported range")
        }
        return try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("source.pdf")
            try VerifiedFileStaging.stage(from: inputURL.resolvingSymlinksInPath(), to: source,
                maximumBytes: 1_073_741_824, describedAs: "the PDF source")
            let summary: LinuxPDFSummary = try request(["summary", source.path, String(maximumPages)], directory: directory, source: inputURL)
            try summary.validate()
            let fingerprint = try ConversionFileFingerprint.read(source)
            return PDFContentSummary(sourceIdentity: ConversionSourceIdentity(name: inputURL.lastPathComponent,
                sha256: fingerprint.sha256, byteCount: fingerprint.byteCount, unavailableReason: nil),
                pageCount: summary.pageCount,
                pages: summary.pages.map { PDFPageSummary(number: $0.number, label: $0.label, width: $0.width, height: $0.height) },
                pagesTruncated: summary.pages.count < summary.pageCount)
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        if context.options.pdfTextRecognition != .disabled && context.options.ocrMethod == .structured {
            throw PlatformBackendUnavailable("structured local document OCR on Linux")
        }
        let source = context.workDirectory.appendingPathComponent("verified-source.pdf")
        try VerifiedFileStaging.stage(from: context.resolvedInputURL, to: source, maximumBytes: 1_073_741_824, describedAs: "the PDF source")
        return try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let summary: LinuxPDFSummary = try request(["summary", source.path, "1"], directory: directory,
                                                       source: context.inputURL, readOnlyPaths: [source])
            try summary.validate()
            let indices: [Int]
            do { indices = try context.options.pdfPages?.zeroBasedIndices(itemCount: summary.pageCount) ?? Array(0..<summary.pageCount) }
            catch { throw failure(context.inputURL, error.localizedDescription) }
            let selection = String(decoding: try JSONEncoder().encode(indices), as: UTF8.self)
            let manifest: LinuxPDFManifest = try request(["extract", source.path, directory.path, selection,
                context.options.pdfTextRecognition.rawValue], directory: directory, source: context.inputURL, readOnlyPaths: [source])
            guard manifest.pageCount == summary.pageCount,
                  manifest.pageFiles == indices.map({ "page-\($0 + 1).json" }) else {
                throw failure(context.inputURL, "the local PDF page manifest is inconsistent")
            }
            var markdown = "# " + MarkdownEscaping.heading(context.inputURL.deletingPathExtension().lastPathComponent)
            var markdownBytes = markdown.utf8.count
            var assets = [String]()
            var warnings = [ConversionWarning.pdfLayoutNotPreserved,
                ConversionWarning(code: "pdf.vectorGraphicsNotExtracted", message: "Vector drawings and unsupported page graphics are not exported as separate assets; inspect visual content in the source PDF.", kind: .contentLoss),
                ConversionWarning(code: "pdf.linuxLayoutApproximation", message: "The Linux PDF backend infers word spacing and bounded text-line order; tables and typographic structure are not reconstructed.", kind: .approximation)]
            var usedOCR = false
            var preparedPages: [(page: LinuxPDFPage, text: String, lines: [PDFTextLine])] = []
            var pageTextBytes = 0
            if manifest.hasAttachments {
                warnings.append(ConversionWarning(code: "pdf.attachmentsNotExtracted", message: "Embedded PDF file attachments were not extracted.", kind: .contentLoss))
            }
            func append(_ value: String) throws {
                guard value.utf8.count <= 128 * 1024 * 1024 - markdownBytes else { throw failure(context.inputURL, "PDF Markdown exceeds its size limit") }
                markdown += value; markdownBytes += value.utf8.count
            }
            for (offset, file) in manifest.pageFiles.enumerated() {
                try ConversionExecution.report(unit: .page, completed: offset, total: indices.count)
                let data = try VerifiedFileStaging.contents(of: directory.appendingPathComponent(file), maximumBytes: 16 * 1024 * 1024,
                                                           describedAs: "the PDF page result")
                var page = try JSONDecoder().decode(LinuxPDFPage.self, from: data)
                guard page.number == indices[offset] + 1 else { throw failure(context.inputURL, "the PDF page identity changed") }
                try page.validate()
                page = page.retainingLayoutOnly()
                pageTextBytes += page.text.utf8.count
                guard pageTextBytes <= 64 * 1024 * 1024 else { throw failure(context.inputURL, "PDF text exceeds its size limit") }
                let location = ConversionLocation(page: page.number)
                var text = ExtractedText.normalized(page.text)
                var layoutLines = page.lines.map { PDFTextLine(text: ExtractedText.normalized($0.text), bounds: $0.rectangle) }
                if page.geometryUnavailable {
                    warnings.append(ConversionWarning(code: "pdf.geometryUnavailable", message: "PDF text was retained without trustworthy character geometry.", location: location, kind: .approximation))
                }
                if let raster = page.ocrRaster {
                    guard raster == "page-\(page.number)-ocr.png" else { throw failure(context.inputURL, "the PDF raster name is invalid") }
                    do {
                        let recognition = try LinuxOCR.recognize(pngURL: directory.appendingPathComponent(raster), languages: context.options.ocrLanguages)
                        usedOCR = true
                        var additions = [String]()
                        var conflict = false
                        for line in recognition.lines {
                            let bounds = CGRect(x: line.bounds.minX * page.width, y: line.bounds.minY * page.height,
                                                width: line.bounds.width * page.width, height: line.bounds.height * page.height)
                            let original = page.lines.filter { $0.rectangle.intersects(bounds) }
                            let key = line.recognized.trimmingCharacters(in: .whitespacesAndNewlines)
                            if original.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == key }) { continue }
                            if !original.isEmpty { conflict = true; continue }
                            if page.geometryUnavailable && text.contains(key) { continue }
                            additions.append(line.text)
                            layoutLines.append(PDFTextLine(text: line.text, bounds: bounds))
                        }
                        if !additions.isEmpty { text += (text.isEmpty ? "" : "\n") + additions.joined(separator: "\n") }
                        if conflict {
                            warnings.append(ConversionWarning(code: "pdf.ocrConflict", message: "OCR text overlapping different embedded text was omitted to protect digital source text.", location: location, kind: .contentLoss))
                        }
                    } catch {
                        try ConversionExecution.check()
                        if case ConversionError.processTimedOut = error { throw error }
                        warnings.append(.pdfOCRFailed.at(location))
                        warnings.append(ConversionWarning(code: "pdf.ocrFailureDetail", message: error.localizedDescription, location: location, kind: .contentLoss))
                    }
                }
                pageTextBytes += text.utf8.count - page.text.utf8.count
                guard pageTextBytes <= 64 * 1024 * 1024 else { throw failure(context.inputURL, "PDF text exceeds its size limit") }
                if text.isEmpty { warnings.append(.pdfPageTextUnavailable.at(location)) }
                preparedPages.append((page, text, layoutLines))
            }
            let originalLines = preparedPages.map(\.lines)
            let pageBounds = preparedPages.map { CGRect(x: 0, y: 0, width: $0.page.width, height: $0.page.height) }
            let filtered = context.options.pdfRemoveHeadersFooters
                ? PDFTextLayout.removingRepeatedMargins(originalLines, bounds: pageBounds) : originalLines
            for (index, prepared) in preparedPages.enumerated() {
                let page = prepared.page
                let location = ConversionLocation(page: page.number)
                var text = prepared.text
                if page.geometryUnavailable {
                    if context.options.pdfRemoveHeadersFooters || context.options.pdfDehyphenate {
                        warnings.append(ConversionWarning(code: "pdf.cleanupGeometryUnavailable", message: "Requested margin cleanup and dehyphenation were not applied to this page because its digital text geometry is unavailable.", location: location, kind: .approximation))
                    }
                } else if context.options.pdfLayout == .automatic || context.options.pdfRemoveHeadersFooters || context.options.pdfDehyphenate {
                    let lines = filtered[index]
                    let ambiguous = PDFTextLayout.hasAmbiguousColumns(lines, pageBounds: pageBounds[index])
                    let ordered = context.options.pdfLayout == .legacy ? lines
                        : (ambiguous ? PDFTextLayout.rowOrdered(lines) : PDFTextLayout.ordered(lines, pageBounds: pageBounds[index]))
                    text = PDFTextLayout.text(ordered, hardHyphens: context.options.pdfDehyphenate)
                    if ambiguous {
                        warnings.append(ConversionWarning(code: "pdf.layoutAmbiguous", message: "Aligned text may be a table or parallel columns; row order was retained.", location: location, kind: .approximation))
                    }
                    if lines.count != originalLines[index].count {
                        warnings.append(ConversionWarning(code: "pdf.repeatedMarginRemoved", message: "Repeated text at the page margin was removed by request.", location: location, kind: .information))
                    }
                }
                let pageOffset = markdownBytes
                try append("\n\n<a id=\"pmt-pdf-page-\(page.number)\"></a>\n\n## Page \(page.number)\n\n")
                try append(text.isEmpty ? "_No text could be extracted from this page._" : MarkdownEscaping.literalBlock(text))
                for image in page.images {
                    let prefix = "page-\(page.number)-image-"
                    guard image.name.hasPrefix(prefix), image.name.hasSuffix(".png"),
                          Int(image.name.dropFirst(prefix.count).dropLast(4)) != nil,
                          URL(fileURLWithPath: image.name).lastPathComponent == image.name else { throw failure(context.inputURL, "the PDF image name is invalid") }
                    let bytes = try VerifiedFileStaging.contents(of: directory.appendingPathComponent(image.name), maximumBytes: 256 * 1024 * 1024,
                                                                describedAs: "a PDF image")
                    var info = pmt_image_info()
                    let status = bytes.withUnsafeBytes { pmt_validate_png($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &info) }
                    guard status == PMT_IMAGE_OK, Int(info.width) == image.width, Int(info.height) == image.height else {
                        throw failure(context.inputURL, "an extracted PDF PNG is invalid")
                    }
                    let relative = "images/" + image.name
                    let target = context.stagedOutputDirectory.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: target, options: .withoutOverwriting)
                    assets.append(relative)
                    try append("\n\n![PDF image](" + MarkdownEscaping.linkDestination(relative) + ")")
                }
                if !page.links.isEmpty {
                    try append("\n\n### Links\n")
                    for link in page.links {
                        let label = (link.label.isEmpty ? "PDF link" : link.label).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        if let uri = link.uri, let scheme = URL(string: uri)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                            try append("\n- [" + MarkdownEscaping.inlineLiteral(label) + "](" + MarkdownEscaping.linkDestination(uri) + ")")
                        } else if let destination = link.destinationPage, indices.contains(destination - 1) {
                            try append("\n- [" + MarkdownEscaping.inlineLiteral(label) + "](#pmt-pdf-page-\(destination))")
                        } else {
                            try append("\n- " + MarkdownEscaping.inlineLiteral((label + " " + (link.uri ?? link.destinationPage.map { "Page \($0)" } ?? "Unsupported PDF action")).split(whereSeparator: \.isWhitespace).joined(separator: " ")))
                            warnings.append(ConversionWarning(code: "pdf.linkTargetUnavailable", message: "A PDF link target was retained as literal text because it was unsafe, unsupported or outside selected pages.", location: location, kind: .contentLoss))
                        }
                    }
                }
                if !page.annotations.isEmpty {
                    try append("\n\n### Annotations")
                    for annotation in page.annotations {
                        if !["text", "popup", "free-text"].contains(annotation.kind) {
                            warnings.append(ConversionWarning(code: "pdf.annotationAppearanceNotPreserved", message: "The annotation's graphical appearance was not retained; readable text and metadata remain available.", location: ConversionLocation(page: page.number, note: "Annotation \(annotation.number)"), kind: .contentLoss))
                        }
                        let author = annotation.author.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        let modified = annotation.modified.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        try append("\n\n#### Annotation \(annotation.number)\n\n" + MarkdownEscaping.literalBlock("Type: \(annotation.kind)\nAuthor: \(author)\nModified (source): \(modified)\nPage rectangle: \(annotation.bounds.map(String.init(describing:)).joined(separator: ", "))\n\n\(annotation.contents)"))
                    }
                    warnings.append(ConversionWarning(code: "pdf.annotationMetadataApproximation", message: "Readable annotation text, author, modification date and page rectangle were retained; advanced annotation fields and exact text references are not reconstructed.", location: location, kind: .approximation))
                }
                ConversionExecution.current?.recording?.record(location, offset: pageOffset, length: markdownBytes - pageOffset)
            }
            if usedOCR {
                warnings.append(.pdfOCRApplied)
                if context.options.ocrLanguages.isEmpty {
                    let languages = try LinuxOCR.resolveLanguages([], available: LinuxOCR.availableLanguages())
                    warnings.append(ConversionWarning(code: "ocr.languageDefault", message: "Local OCR used the installed default language: \(languages.joined(separator: ", ")). Choose explicit languages for multilingual text.", kind: .information))
                }
            }
            if !assets.isEmpty {
                warnings.append(ConversionWarning(code: "pdf.imagesRasterized", message: "Embedded PDF images were retained as local PNG assets; their original compression and page placement were not preserved.", kind: .approximation))
            }
            try append("\n")
            try ConversionExecution.report(unit: .page, completed: indices.count, total: indices.count)
            return StagedConversionResult(markdownRelativePath: try context.writeMarkdown(markdown), assetRelativePaths: assets,
                                          warnings: warnings, metadata: manifest.metadata.documentMetadata)
        }
    }

    private func request<T: Decodable>(_ arguments: [String], directory: URL, source: URL, readOnlyPaths: [URL] = []) throws -> T {
        let result = try LinuxBackendResources.runPython(script: "poppler", arguments: arguments, in: directory,
            readOnlyPaths: readOnlyPaths, timeout: ConversionExecution.current?.processTimeout ?? 30)
        if result.status == 69 { throw PlatformBackendUnavailable("Python GI Poppler/Cairo PDF") }
        if result.status == 74 { throw ConversionError.fileSystemFailure(result.standardError) }
        guard result.status == 0, result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure(source, result.standardError.isEmpty ? "the local PDF backend failed" : result.standardError) }
        guard let data = result.standardOutput.data(using: .utf8) else { throw failure(source, "the local PDF backend returned invalid text") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func failure(_ source: URL, _ reason: String) -> ConversionError { .invalidInput(source, format: .pdf, reason: reason) }
}

private struct LinuxPDFMetadata: Decodable {
    let title: String, author: String, subject: String, keywords: String
    let created: Double?, modified: Double?
    var documentMetadata: DocumentMetadata {
        DocumentMetadata(title: title, author: author, subject: subject, keywords: DocumentMetadata.splitKeywords(keywords),
                         created: created.map { Date(timeIntervalSince1970: $0) },
                         modified: modified.map { Date(timeIntervalSince1970: $0) })
    }
}
private struct LinuxPDFPageSummary: Decodable { let number: Int; let label: String; let width: Double; let height: Double }
private struct LinuxPDFSummary: Decodable {
    let pageCount: Int; let pages: [LinuxPDFPageSummary]; let metadata: LinuxPDFMetadata
    func validate() throws {
        guard (1...1000).contains(pageCount), !pages.isEmpty, pages.count <= pageCount,
              pages.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 && $0.element.width.isFinite && $0.element.height.isFinite && $0.element.width > 0 && $0.element.height > 0 }) else {
            throw ConversionError.fileSystemFailure("the local PDF summary is invalid")
        }
    }
}
private struct LinuxPDFManifest: Decodable { let pageCount: Int; let pageFiles: [String]; let metadata: LinuxPDFMetadata; let hasAttachments: Bool }
private struct LinuxPDFLine: Decodable {
    let text: String; let bounds: [Double]
    var rectangle: CGRect { CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]) }
}
private struct LinuxPDFLink: Decodable { let bounds: [Double]; let uri: String?; let destinationPage: Int?; let label: String }
private struct LinuxPDFAnnotation: Decodable { let number: Int; let kind: String; let contents: String; let author: String; let modified: String; let bounds: [Double] }
private struct LinuxPDFImage: Decodable { let name: String; let width: Int; let height: Int; let bounds: [Double] }
private struct LinuxPDFPage: Decodable {
    let number: Int; let width: Double; let height: Double; let label: String; let text: String
    let characterRects: [[Double]]; let lines: [LinuxPDFLine]; let geometryUnavailable: Bool
    let links: [LinuxPDFLink]; let annotations: [LinuxPDFAnnotation]; let images: [LinuxPDFImage]; let ocrRaster: String?
    func retainingLayoutOnly() -> Self {
        let texts = geometryUnavailable ? nil : LinuxPDFTextGeometry.lines(text: text, rectangles: characterRects)
        let retainedLines: [LinuxPDFLine]
        if let texts, texts.count == lines.count {
            retainedLines = zip(lines, texts).map { LinuxPDFLine(text: $1, bounds: $0.bounds) }
        } else { retainedLines = lines }
        return Self(number: number, width: width, height: height, label: label, text: text,
             characterRects: [], lines: retainedLines, geometryUnavailable: geometryUnavailable,
             links: links, annotations: annotations, images: images, ocrRaster: ocrRaster)
    }
    func validate() throws {
        let rectangles = characterRects + lines.map(\.bounds) + links.map(\.bounds) + annotations.map(\.bounds) + images.map(\.bounds)
        guard (1...1000).contains(number), width.isFinite, height.isFinite, width > 0, height > 0,
              characterRects.count <= 100_000, links.allSatisfy({ $0.destinationPage.map { $0 > 0 } ?? true }), links.count + annotations.count <= 8192, images.count <= 4096,
              rectangles.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) && $0[2] >= 0 && $0[3] >= 0 }),
              images.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.height <= 16_000_000 && $0.width <= 16_000_000 / $0.height }) else {
            throw ConversionError.fileSystemFailure("the local PDF page result is invalid")
        }
        if !geometryUnavailable {
            func inventory(_ text: String) -> [UInt32: Int] {
                var values: [UInt32: Int] = [:]
                for scalar in ExtractedText.normalized(text).unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    values[scalar.value, default: 0] += 1
                }
                return values
            }
            guard characterRects.count == text.unicodeScalars.count,
                  inventory(text) == inventory(lines.map(\.text).joined(separator: "\n")) else {
                throw ConversionError.fileSystemFailure("the local PDF text geometry does not preserve its character inventory")
            }
        }
    }
}
#endif
