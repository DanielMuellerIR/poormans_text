import CoreGraphics
import Foundation
import PDFKit

/// Liest PDFs ausschließlich über die macOS-Systemframeworks. Textseiten bleiben
/// bei PDFKit; nur Seiten ohne ausreichend eingebetteten Text werden lokal
/// gerendert und durch Vision gelesen.
struct PDFAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors: [SupportedFormat] = [
        SupportedFormat(
            format: .pdf,
            fileExtensions: ["pdf"],
            containerKind: .file,
            requiredTools: []
        )
    ]

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let hasPDFExtension = inputURL.pathExtension.lowercased() == "pdf"
        let resolvedURL = inputURL.resolvingSymlinksInPath()

        do {
            let prefix = try VerifiedFileStaging.prefix(
                of: resolvedURL,
                maximumBytes: PDFImportLimits.maximumSourceBytes,
                prefixBytes: PDFImportLimits.signatureBytes,
                describedAs: "the PDF source"
            )
            guard prefix.range(of: Data("%PDF-".utf8)) != nil else {
                throw PDFAdapterError("the PDF signature is missing")
            }
            _ = try VerifiedFileStaging.withTemporaryCopy(
                of: resolvedURL,
                maximumBytes: PDFImportLimits.maximumSourceBytes,
                describedAs: "the PDF source",
                fileExtension: "pdf"
            ) { snapshot in
                try validatedDocument(at: snapshot)
            }
            return .match(
                AdapterInputInspection(
                    format: .pdf,
                    priority: 107,
                    expectedWarnings: [.pdfLayoutNotPreserved]
                )
            )
        } catch {
            return hasPDFExtension
                ? .invalid(format: .pdf, priority: 107, reason: error.localizedDescription)
                : .noMatch
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        guard context.format == .pdf else {
            throw ConversionError.unsupportedInput(context.inputURL)
        }

        let stagedInput = context.workDirectory.appendingPathComponent("verified-source.pdf")
        do {
            try VerifiedFileStaging.stage(
                from: context.resolvedInputURL,
                to: stagedInput,
                maximumBytes: PDFImportLimits.maximumSourceBytes,
                describedAs: "the PDF source"
            )
        } catch let error as VerifiedFileStaging.StagingError where error.kind == .source {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .pdf,
                reason: error.reason
            )
        } catch let error as VerifiedFileStaging.StagingError {
            throw ConversionError.fileSystemFailure(error.reason)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        let document: PDFDocument
        do {
            document = try validatedDocument(at: stagedInput)
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .pdf,
                reason: "the verified PDF source changed after inspection: \(error.localizedDescription)"
            )
        }

        let extracted: PDFExtraction
        do {
            extracted = try extractText(from: document)
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .pdf,
                reason: error.localizedDescription
            )
        }

        let markdownName = context.inputURL.deletingPathExtension().lastPathComponent + ".md"
        let markdownURL = context.stagedOutputDirectory.appendingPathComponent(markdownName)
        let markdown: String
        do {
            markdown = try renderedMarkdown(from: extracted.pages, sourceURL: context.inputURL)
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .pdf,
                reason: error.localizedDescription
            )
        }
        do {
            try Data(markdown.utf8).write(to: markdownURL, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        var warnings = [ConversionWarning.pdfLayoutNotPreserved]
        if extracted.usedOCR {
            warnings.append(.pdfOCRApplied)
        }
        if extracted.hadOCRFailure {
            warnings.append(.pdfOCRFailed)
        }
        if extracted.hasPageWithoutText {
            warnings.append(.pdfPageTextUnavailable)
        }
        return StagedConversionResult(
            markdownRelativePath: markdownName,
            assetRelativePaths: [],
            warnings: warnings,
            metadata: Self.metadata(of: document)
        )
    }

    /// Das Info-Wörterbuch des PDFs; PDFKit liefert Daten schon als `Date`.
    private static func metadata(of document: PDFDocument) -> DocumentMetadata {
        let attributes = document.documentAttributes ?? [:]
        func string(_ key: PDFDocumentAttribute) -> String? {
            attributes[key] as? String
        }
        func date(_ key: PDFDocumentAttribute) -> Date? {
            attributes[key] as? Date
        }
        return DocumentMetadata(
            title: string(.titleAttribute),
            author: string(.authorAttribute),
            subject: string(.subjectAttribute),
            keywords: (attributes[PDFDocumentAttribute.keywordsAttribute] as? [String])
                ?? string(.keywordsAttribute).map(DocumentMetadata.splitKeywords) ?? [],
            created: date(.creationDateAttribute),
            modified: date(.modificationDateAttribute)
        )
    }

    private func validatedDocument(at url: URL) throws -> PDFDocument {
        // Regularität, Größe und Signatur hängen an EINEM Deskriptor. Vorher
        // beschrieb `resourceValues` den Pfad und `FileHandle` öffnete ihn
        // danach ein zweites Mal — ohne `O_NONBLOCK`, sodass eine
        // untergeschobene FIFO das Öffnen ohne Zeitgrenze anhalten konnte.
        try VerifiedFile.open(at: url, failure: Self.sourceFailure) { source in
            guard source.isRegularFile else {
                throw PDFAdapterError("the PDF source is not a regular file")
            }
            guard source.info.st_size <= Int64(PDFImportLimits.maximumSourceBytes) else {
                throw PDFAdapterError("the PDF source exceeds the supported size limit")
            }
            guard try hasPDFSignature(source) else {
                throw PDFAdapterError("the PDF signature is missing")
            }
        }
        // PDFKit öffnet den Pfad selbst; der Aufrufer übergibt ihm deshalb nur
        // eine private Kopie, die aus dem geprüften Deskriptor entstanden ist.
        guard let document = PDFDocument(url: url) else {
            throw PDFAdapterError("the PDF document is damaged or unreadable")
        }
        guard !document.isEncrypted else {
            throw PDFAdapterError("password-protected PDFs are not supported")
        }
        guard !document.isLocked else {
            throw PDFAdapterError("the PDF document is locked")
        }
        guard document.pageCount > 0 else {
            throw PDFAdapterError("the PDF document contains no pages")
        }
        guard document.pageCount <= PDFImportLimits.maximumPages else {
            throw PDFAdapterError("the PDF document exceeds the supported page limit")
        }
        return document
    }

    /// Ein PDF darf einen Vorspann haben; `%PDF-` muss deshalb nur innerhalb
    /// der ersten Bytes stehen, nicht ganz am Anfang.
    private func hasPDFSignature(_ source: VerifiedFile) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: PDFImportLimits.signatureBytes)
        let readTotal = try bytes.withUnsafeMutableBytes { raw in
            try source.readFully(into: raw)
        }
        return Data(bytes[0..<readTotal]).range(of: Data("%PDF-".utf8)) != nil
    }

    private static func sourceFailure(_ reason: VerifiedFile.Failure) -> Error {
        switch reason {
        case .couldNotOpen(let detail):
            PDFAdapterError("the PDF source could not be opened: \(detail)")
        case .couldNotInspect:
            PDFAdapterError("the PDF source could not be inspected")
        case .couldNotRead:
            PDFAdapterError("the PDF source could not be read")
        }
    }

    private func extractText(from document: PDFDocument) throws -> PDFExtraction {
        var pages = [String]()
        var ocrPlans = [OCRPlan]()
        var extractedTextBytes = 0

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                throw PDFAdapterError("the PDF page \(pageIndex + 1) is unreadable")
            }
            let extractedText = normalizedText(page.string ?? "")
            if extractedText.count >= PDFImportLimits.minimumEmbeddedTextCharacters {
                try accountText(extractedText, totalBytes: &extractedTextBytes)
                pages.append(extractedText)
            } else {
                let dimensions = try rasterDimensions(for: page)
                ocrPlans.append(OCRPlan(index: pageIndex, page: page, dimensions: dimensions))
                // Der wenige eingebettete Text bleibt als Rückfall stehen.
                // Liefert die OCR nichts oder scheitert sie, ist er weiterhin
                // das, was im Dokument steht — ihn zu verwerfen wäre
                // Inhaltsverlust.
                try accountText(extractedText, totalBytes: &extractedTextBytes)
                pages.append(extractedText)
            }
        }

        let plannedPixels = ocrPlans.reduce(0) { partial, plan in
            partial + plan.dimensions.pixelCount
        }
        guard plannedPixels <= PDFImportLimits.maximumOCRPixels else {
            throw PDFAdapterError("the PDF pages selected for OCR exceed the pixel budget")
        }

        var hadOCRFailure = false
        for plan in ocrPlans {
            let recognizedText: String
            do {
                recognizedText = try recognizeText(in: plan.page, dimensions: plan.dimensions)
            } catch {
                hadOCRFailure = true
                continue
            }
            // Hat die OCR nichts gefunden, bleibt der eingebettete Rückfall
            // stehen statt einer leeren Seite.
            guard !recognizedText.isEmpty else { continue }
            // Der Rückfall wird ersetzt, also gibt er seinen Anteil am Budget
            // wieder frei.
            extractedTextBytes -= pages[plan.index].lengthOfBytes(using: .utf8)
            try accountText(recognizedText, totalBytes: &extractedTextBytes)
            pages[plan.index] = recognizedText
        }
        return PDFExtraction(
            pages: pages,
            usedOCR: !ocrPlans.isEmpty,
            hadOCRFailure: hadOCRFailure,
            hasPageWithoutText: pages.contains { $0.isEmpty }
        )
    }

    private func accountText(_ text: String, totalBytes: inout Int) throws {
        let byteCount = text.lengthOfBytes(using: .utf8)
        guard byteCount <= PDFImportLimits.maximumExtractedTextBytes - totalBytes else {
            throw PDFAdapterError("the PDF text exceeds the supported size limit")
        }
        totalBytes += byteCount
    }

    private func rasterDimensions(for page: PDFPage) throws -> RasterDimensions {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            throw PDFAdapterError("a PDF page has invalid dimensions")
        }
        let fullResolutionPixels = bounds.width * bounds.height * PDFImportLimits.ocrScale
            * PDFImportLimits.ocrScale
        guard fullResolutionPixels.isFinite, fullResolutionPixels > 0 else {
            throw PDFAdapterError("a PDF page exceeds the OCR pixel budget")
        }
        let scale = min(
            PDFImportLimits.ocrScale,
            sqrt(Double(PDFImportLimits.maximumPixelsPerPage) / fullResolutionPixels)
        )
        let renderedWidth = ceil(bounds.width * scale)
        let renderedHeight = ceil(bounds.height * scale)
        guard scale.isFinite, scale > 0,
              renderedWidth.isFinite, renderedHeight.isFinite,
              renderedWidth <= Double(PDFImportLimits.maximumRasterDimension),
              renderedHeight <= Double(PDFImportLimits.maximumRasterDimension) else {
            throw PDFAdapterError("a PDF page exceeds the OCR pixel budget")
        }
        let width = Int(renderedWidth)
        let height = Int(renderedHeight)
        guard width > 0, height > 0,
              width <= PDFImportLimits.maximumPixelsPerPage / height else {
            throw PDFAdapterError("a PDF page exceeds the OCR pixel budget")
        }
        return RasterDimensions(bounds: bounds, scale: scale, width: width, height: height)
    }

    private func recognizeText(in page: PDFPage, dimensions: RasterDimensions) throws -> String {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: dimensions.width,
            height: dimensions.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFAdapterError("the PDF page could not be rendered for OCR")
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height))
        context.translateBy(x: 0, y: CGFloat(dimensions.height))
        context.scaleBy(x: dimensions.scale, y: -dimensions.scale)
        context.translateBy(x: -dimensions.bounds.minX, y: -dimensions.bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else {
            throw PDFAdapterError("the rendered PDF page has no image")
        }

        return try VisionTextRecognizer.recognize(in: image).text
    }

    private func renderedMarkdown(from pages: [String], sourceURL: URL) throws -> String {
        var markdown = ""
        var markdownBytes = 0
        try appendMarkdown(
            "# \(MarkdownEscaping.heading(sourceURL.deletingPathExtension().lastPathComponent))",
            to: &markdown,
            byteCount: &markdownBytes
        )
        for (index, text) in pages.enumerated() {
            let content = text.isEmpty
                ? "_No text could be extracted from this page._"
                : MarkdownEscaping.literalBlock(text)
            try appendMarkdown(
                "\n\n## Page \(index + 1)\n\n\(content)",
                to: &markdown,
                byteCount: &markdownBytes
            )
        }
        try appendMarkdown("\n", to: &markdown, byteCount: &markdownBytes)
        return markdown
    }

    private func appendMarkdown(
        _ text: String,
        to markdown: inout String,
        byteCount totalByteCount: inout Int
    ) throws {
        let addedByteCount = text.lengthOfBytes(using: .utf8)
        guard addedByteCount <= PDFImportLimits.maximumMarkdownBytes - totalByteCount else {
            throw PDFAdapterError("the PDF Markdown output exceeds the supported size limit")
        }
        totalByteCount += addedByteCount
        markdown += text
    }

    private func normalizedText(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let safeScalars = unified.unicodeScalars.filter {
            $0.value == 0x0A || $0.value == 0x09 || $0.value >= 0x20 && $0.value != 0x7F
        }
        return String(String.UnicodeScalarView(safeScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct PDFExtraction {
        let pages: [String]
        let usedOCR: Bool
        let hadOCRFailure: Bool
        let hasPageWithoutText: Bool
    }

    private struct OCRPlan {
        let index: Int
        let page: PDFPage
        let dimensions: RasterDimensions
    }

    private struct RasterDimensions {
        let bounds: CGRect
        let scale: CGFloat
        let width: Int
        let height: Int

        var pixelCount: Int { width * height }
    }

}

private enum PDFImportLimits {
    static let maximumSourceBytes = 1_073_741_824
    static let signatureBytes = 1_024
    static let maximumPages = 1_000
    static let minimumEmbeddedTextCharacters = 20
    static let ocrScale: CGFloat = 2
    static let maximumPixelsPerPage = 16_000_000
    static let maximumOCRPixels = 64_000_000
    static let maximumRasterDimension = 16_384
    /// Markdown-Metazeichen können den Rohtext beim Maskieren höchstens etwa
    /// verdoppeln. 64 MiB Quelltext bleiben daher unter dem 128-MiB-
    /// Ausgabebudget, das auch die Tabellenkonvertierung schützt.
    static let maximumExtractedTextBytes = 64 * 1_024 * 1_024
    static let maximumMarkdownBytes = 128 * 1_024 * 1_024
}

private struct PDFAdapterError: LocalizedError {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var errorDescription: String? { reason }
}
