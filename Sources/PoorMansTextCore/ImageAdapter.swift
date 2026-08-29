import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Übernimmt unterstützte Bilddateien bytegenau als Asset und ergänzt auf
/// Wunsch lokal erkannten Text. Das Original bleibt die maßgebliche Darstellung;
/// OCR ist immer ein zusätzliches, überprüfbares Hilfsmittel.
struct ImageAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors: [SupportedFormat] = [
        SupportedFormat(
            format: .image,
            fileExtensions: ["png", "jpg", "jpeg", "heic", "tif", "tiff"],
            containerKind: .file,
            requiredTools: []
        )
    ]

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let hasImageExtension = Self.imageExtensions.contains(inputURL.pathExtension.lowercased())
        do {
            _ = try imageProbe(at: inputURL.resolvingSymlinksInPath())
            return .match(
                AdapterInputInspection(format: .image, priority: detectionPriority, expectedWarnings: [])
            )
        } catch {
            return hasImageExtension
                ? .invalid(format: .image, priority: detectionPriority, reason: error.localizedDescription)
                : .noMatch
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        guard context.format == .image else {
            throw ConversionError.unsupportedInput(context.inputURL)
        }

        let stagedSource = context.workDirectory.appendingPathComponent("verified-image-source")
        do {
            try VerifiedFileStaging.stage(
                from: context.resolvedInputURL,
                to: stagedSource,
                maximumBytes: ImageImportLimits.maximumSourceBytes,
                describedAs: "the image source"
            )
        } catch let error as VerifiedFileStaging.StagingError where error.kind == .source {
            throw ConversionError.invalidInput(context.inputURL, format: .image, reason: error.reason)
        } catch let error as VerifiedFileStaging.StagingError {
            throw ConversionError.fileSystemFailure(error.reason)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        let probe: ImageProbe
        do {
            probe = try imageProbe(at: stagedSource)
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .image,
                reason: "the verified image source changed after inspection: \(error.localizedDescription)"
            )
        }

        let assetRelativePath = "images/image01.\(probe.fileFormat.fileExtension)"
        let assetURL = context.stagedOutputDirectory.appendingPathComponent(assetRelativePath)
        do {
            try FileManager.default.createDirectory(
                at: assetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: stagedSource, to: assetURL)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        let extraction: ImageExtraction?
        if context.options.imageTextRecognition == .enabled {
            do {
                extraction = try recognizeText(at: stagedSource, frameCount: probe.frameCount)
            } catch {
                throw ConversionError.invalidInput(context.inputURL, format: .image, reason: error.localizedDescription)
            }
        } else {
            extraction = nil
        }

        let markdownName = markdownFilename(for: context.inputURL)
        let markdownURL = context.stagedOutputDirectory.appendingPathComponent(markdownName)
        let markdown: String
        do {
            markdown = try renderedMarkdown(
                sourceURL: context.inputURL,
                assetRelativePath: assetRelativePath,
                extraction: extraction
            )
            try Data(markdown.utf8).write(to: markdownURL, options: .atomic)
        } catch let error as ImageAdapterError {
            throw ConversionError.invalidInput(context.inputURL, format: .image, reason: error.reason)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        var warnings = [ConversionWarning]()
        if let extraction {
            warnings.append(.imageOCRApplied)
            if extraction.wasDownscaled {
                warnings.append(.imageOCRDownscaled)
            }
            if extraction.hadOCRFailure {
                warnings.append(.imageOCRFailed)
            }
            if extraction.hasFrameWithoutText {
                warnings.append(.imageTextUnavailable)
            }
        }
        return StagedConversionResult(
            markdownRelativePath: markdownName,
            assetRelativePaths: [assetRelativePath],
            warnings: warnings
        )
    }

    private func imageProbe(at url: URL) throws -> ImageProbe {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        } catch {
            throw ImageAdapterError(error.localizedDescription)
        }
        guard values.isRegularFile == true else {
            throw ImageAdapterError("the image source is not a regular file")
        }
        guard let size = values.fileSize, size <= ImageImportLimits.maximumSourceBytes else {
            throw ImageAdapterError("the image source exceeds the supported size limit")
        }
        guard let source = imageSource(at: url),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let fileFormat = ImageFileFormat(typeIdentifier: typeIdentifier) else {
            throw ImageAdapterError("the image format is unsupported or unreadable")
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            throw ImageAdapterError("the image contains no frames")
        }
        guard frameCount <= ImageImportLimits.maximumFrames else {
            throw ImageAdapterError("the image exceeds the supported frame limit")
        }
        return ImageProbe(fileFormat: fileFormat, frameCount: frameCount)
    }

    private func recognizeText(at sourceURL: URL, frameCount: Int) throws -> ImageExtraction {
        guard let source = imageSource(at: sourceURL) else {
            throw ImageAdapterError("the verified image source is unreadable")
        }

        // Jeder Frame bekommt seinen Anteil am gemeinsamen Budget, höchstens
        // aber die Frame-Grenze. Ein zu großes Bild wird für die Erkennung
        // kleingerechnet statt abgelehnt: Das Original bleibt die maßgebliche
        // Darstellung, OCR ist der Zusatz — ein gewöhnliches 24-Megapixel-Foto
        // darf daran nicht scheitern. Selbst die erlaubten 1.000 TIFF-Frames
        // bekommen so noch 64.000 Pixel je Frame.
        let frameBudget = min(
            ImageImportLimits.maximumPixelsPerFrame,
            ImageImportLimits.maximumOCRPixels / frameCount
        )

        var pages = [String]()
        var hadOCRFailure = false
        var wasDownscaled = false
        for frameIndex in 0..<frameCount {
            let properties = try frameProperties(source, at: frameIndex)
            let dimensions = try frameDimensions(from: properties, frameIndex: frameIndex)
            let maximumEdge = downscaledEdge(for: dimensions, budget: frameBudget)
            if maximumEdge != nil {
                wasDownscaled = true
            }

            guard let image = decodedImage(source, at: frameIndex, maximumEdge: maximumEdge) else {
                hadOCRFailure = true
                pages.append("")
                continue
            }
            let orientation = imageOrientation(from: properties)
            do {
                pages.append(try VisionTextRecognizer.recognize(in: image, orientation: orientation).text)
            } catch {
                hadOCRFailure = true
                pages.append("")
            }
        }
        return ImageExtraction(
            frames: pages,
            hadOCRFailure: hadOCRFailure,
            wasDownscaled: wasDownscaled,
            hasFrameWithoutText: pages.contains { $0.isEmpty }
        )
    }

    /// Die längste Kante, auf die dieser Frame für die Erkennung
    /// herunterzurechnen ist — `nil`, wenn er ohnehin ins Budget passt und
    /// unverändert dekodiert werden darf.
    private func downscaledEdge(for dimensions: FrameDimensions, budget: Int) -> Int? {
        guard dimensions.width > budget / dimensions.height else {
            return nil
        }
        // In Double gerechnet: Das Produkt zweier Metadatenwerte kann den
        // Int-Bereich sprengen, und genau deshalb steht die Prüfung oben als
        // Division statt als Multiplikation.
        let area = Double(dimensions.width) * Double(dimensions.height)
        let scale = (Double(budget) / area).squareRoot()
        let longestEdge = Double(max(dimensions.width, dimensions.height)) * scale
        return max(1, Int(longestEdge.rounded(.down)))
    }

    /// Dekodiert den Frame — bei Bedarf gleich verkleinert. Die volle
    /// Pixelmenge entsteht dann gar nicht erst, weil ImageIO die Verkleinerung
    /// beim Dekodieren erledigt. Die EXIF-Orientierung bleibt dabei bewusst
    /// unangewandt: Sie geht getrennt an Vision, und ein doppeltes Drehen
    /// würde die Leserichtung verderben.
    private func decodedImage(
        _ source: CGImageSource,
        at index: Int,
        maximumEdge: Int?
    ) -> CGImage? {
        guard let maximumEdge else {
            return CGImageSourceCreateImageAtIndex(source, index, imageOptions())
        }
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            index,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
                kCGImageSourceShouldCache: false,
            ] as CFDictionary
        )
    }

    private func frameProperties(_ source: CGImageSource, at index: Int) throws -> [CFString: Any] {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any] else {
            throw ImageAdapterError("the image frame \(index + 1) has no readable metadata")
        }
        return properties
    }

    /// Die Pixelmaße eines Frames aus seinen Metadaten — gelesen, bevor
    /// irgendein Pixel dekodiert wird.
    private func frameDimensions(
        from properties: [CFString: Any],
        frameIndex: Int
    ) throws -> FrameDimensions {
        // `Int(exactly:)` statt eines Vergleichs mit `Double(Int.max)`: Dieser
        // Wert ist 2^63 und damit selbst KEIN gültiges Int — ein `<=`-Vergleich
        // ließ ihn durch, und die Umwandlung danach hätte den Prozess beendet.
        // Über echte Bilddateien ist das nicht erreichbar, weil PNG, JPEG, TIFF
        // und HEIC ihre Maße in 32 Bit ablegen; ein Absturzpfad soll in einem
        // Leser fremder Dateien trotzdem nicht stehen bleiben.
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite,
              width >= 1, height >= 1,
              let integerWidth = Int(exactly: width.rounded(.down)),
              let integerHeight = Int(exactly: height.rounded(.down)) else {
            throw ImageAdapterError("the image frame \(frameIndex + 1) has invalid dimensions")
        }
        return FrameDimensions(width: integerWidth, height: integerHeight)
    }

    private func imageOrientation(from properties: [CFString: Any]) -> CGImagePropertyOrientation {
        guard let value = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
              let orientation = CGImagePropertyOrientation(rawValue: value) else {
            return .up
        }
        return orientation
    }

    private func renderedMarkdown(
        sourceURL: URL,
        assetRelativePath: String,
        extraction: ImageExtraction?
    ) throws -> String {
        let filename = sourceURL.deletingPathExtension().lastPathComponent
        let displayName = filename.isEmpty ? "Image" : filename
        let escapedName = MarkdownEscaping.heading(displayName)
        var markdown = ""
        var markdownBytes = 0
        try appendMarkdown("# \(escapedName)\n\n![\(escapedName)](\(assetRelativePath))", to: &markdown, byteCount: &markdownBytes)

        guard let extraction else {
            try appendMarkdown("\n", to: &markdown, byteCount: &markdownBytes)
            return markdown
        }
        try appendMarkdown("\n\n## OCR text", to: &markdown, byteCount: &markdownBytes)
        if extraction.frames.count == 1 {
            try appendMarkdown(
                "\n\n\(markdownText(for: extraction.frames[0]))\n",
                to: &markdown,
                byteCount: &markdownBytes
            )
            return markdown
        }
        for (index, text) in extraction.frames.enumerated() {
            try appendMarkdown(
                "\n\n### Frame \(index + 1)\n\n\(markdownText(for: text))",
                to: &markdown,
                byteCount: &markdownBytes
            )
        }
        try appendMarkdown("\n", to: &markdown, byteCount: &markdownBytes)
        return markdown
    }

    private func markdownText(for text: String) -> String {
        text.isEmpty
            ? "_No text could be extracted from this image frame._"
            : MarkdownEscaping.literalBlock(text)
    }

    private func appendMarkdown(
        _ text: String,
        to markdown: inout String,
        byteCount totalByteCount: inout Int
    ) throws {
        let addedByteCount = text.lengthOfBytes(using: .utf8)
        guard addedByteCount <= ImageImportLimits.maximumMarkdownBytes - totalByteCount else {
            throw ImageAdapterError("the image Markdown output exceeds the supported size limit")
        }
        totalByteCount += addedByteCount
        markdown += text
    }

    private func markdownFilename(for sourceURL: URL) -> String {
        let name = sourceURL.deletingPathExtension().lastPathComponent
        return (name.isEmpty ? "Image" : name) + ".md"
    }

    private func imageSource(at url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, imageOptions())
    }

    private func imageOptions() -> CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]
    private let detectionPriority = 106

    private struct ImageProbe {
        let fileFormat: ImageFileFormat
        let frameCount: Int
    }

    private struct FrameDimensions {
        let width: Int
        let height: Int
    }

    private struct ImageExtraction {
        let frames: [String]
        let hadOCRFailure: Bool
        /// Wahr, sobald ein Frame für die Erkennung verkleinert wurde.
        let wasDownscaled: Bool
        let hasFrameWithoutText: Bool
    }
}

private enum ImageFileFormat {
    case png
    case jpeg
    case heic
    case tiff

    init?(typeIdentifier: String) {
        switch typeIdentifier {
        case UTType.png.identifier:
            self = .png
        case UTType.jpeg.identifier:
            self = .jpeg
        case UTType.heic.identifier:
            self = .heic
        case UTType.tiff.identifier:
            self = .tiff
        default:
            return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }
}

private enum ImageImportLimits {
    static let maximumSourceBytes = 1_073_741_824
    static let maximumFrames = 1_000
    static let maximumPixelsPerFrame = 16_000_000
    static let maximumOCRPixels = 64_000_000
    static let maximumMarkdownBytes = 128 * 1_024 * 1_024
}

private struct ImageAdapterError: LocalizedError {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var errorDescription: String? { reason }
}
