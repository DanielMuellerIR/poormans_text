#if os(Linux)
import Foundation

struct LinuxImageAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors = [PlatformFormatDescriptors.image]

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let expected = PlatformFormatDescriptors.image.fileExtensions.contains(inputURL.pathExtension.lowercased())
        do {
            let prefix = try VerifiedFileStaging.prefix(of: inputURL.resolvingSymlinksInPath(),
                maximumBytes: 1_073_741_824, prefixBytes: 16, describedAs: "the image source")
            guard Self.hasSignature(prefix) else {
                return expected ? .invalid(format: .image, priority: 106, reason: "the image signature is missing") : .noMatch
            }
            _ = try LinuxRasterBackend.inspect(source: inputURL.resolvingSymlinksInPath())
            return .match(AdapterInputInspection(format: .image, priority: 106, expectedWarnings: []))
        } catch let error as PlatformBackendUnavailable {
            throw error
        } catch {
            try ConversionExecution.check()
            if case ConversionError.processTimedOut = error { throw error }
            if case ConversionError.fileSystemFailure = error { throw error }
            return expected ? .invalid(format: .image, priority: 106, reason: error.localizedDescription) : .noMatch
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        if context.options.imageTextRecognition == .enabled && context.options.ocrMethod == .structured {
            throw PlatformBackendUnavailable("structured OCR")
        }
        let snapshot = context.workDirectory.appendingPathComponent("verified-image-source")
        try VerifiedFileStaging.stage(from: context.resolvedInputURL, to: snapshot,
            maximumBytes: 1_073_741_824, describedAs: "the image source")
        let recognize = context.options.imageTextRecognition == .enabled
        return try LinuxRasterBackend.withFrames(source: snapshot, render: recognize) { inspection, directory in
            let asset = "images/image01.\(inspection.fileExtension)"
            let assetURL = context.stagedOutputDirectory.appendingPathComponent(asset)
            try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: snapshot, to: assetURL)
            let stem = context.inputURL.deletingPathExtension().lastPathComponent
            let name = stem.isEmpty ? "Image" : stem
            let heading = MarkdownEscaping.heading(name)
            var markdown = "# \(heading)\n\n![\(heading)](\(asset))"
            var diagnostics = BoundedConversionDiagnostics()
            if recognize {
                diagnostics.append(.imageOCRApplied)
                if context.options.ocrLanguages.isEmpty,
                   let selected = try? LinuxOCR.resolveLanguages([], available: LinuxOCR.availableLanguages()) {
                    diagnostics.append(ConversionWarning(code: "ocr.languageDefault",
                        message: "Linux standard OCR uses the installed language data: \(selected.joined(separator: ", ")). Select OCR languages explicitly for other text.",
                        kind: .information))
                }
                markdown += "\n\n## OCR text"
                for index in 0..<inspection.frameCount {
                    try ConversionExecution.report(unit: .frame, completed: index, total: inspection.frameCount)
                    let location = ConversionLocation(frame: index + 1)
                    if inspection.frames[index].downscaled == true { diagnostics.append(ConversionWarning.imageOCRDownscaled.at(location)) }
                    let text: String
                    do {
                        let png = directory.appendingPathComponent("frame-\(index + 1).png")
                        text = try LinuxOCR.recognize(pngURL: png, languages: context.options.ocrLanguages).text
                    } catch {
                        try ConversionExecution.check()
                        diagnostics.append(ConversionWarning.imageOCRFailed.at(location))
                        diagnostics.append(ConversionWarning(code: "ocr.backendFailure", message: error.localizedDescription,
                            location: location, kind: .contentLoss))
                        text = ""
                    }
                    if text.isEmpty { diagnostics.append(ConversionWarning.imageTextUnavailable.at(location)) }
                    let offset = markdown.utf8.count
                    if inspection.frameCount > 1 { markdown += "\n\n### Frame \(index + 1)" }
                    markdown += "\n\n" + (text.isEmpty ? "_No text could be extracted from this image frame._" : MarkdownEscaping.literalBlock(text))
                    let length = markdown.utf8.count - offset
                    guard markdown.utf8.count <= 128 * 1024 * 1024 else {
                        throw ConversionError.fileSystemFailure("the image Markdown exceeds its size limit")
                    }
                    ConversionExecution.current?.recording?.record(location, offset: offset, length: length)
                }
                try ConversionExecution.report(unit: .frame, completed: inspection.frameCount, total: inspection.frameCount)
            }
            markdown += "\n"
            let filename = name + ".md"
            try Data(markdown.utf8).write(to: context.stagedOutputDirectory.appendingPathComponent(filename), options: .atomic)
            return StagedConversionResult(markdownRelativePath: filename, assetRelativePaths: [asset], warnings: diagnostics.result)
        }
    }

    private static func hasSignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) || bytes.starts(with: [255, 216, 255]) { return true }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return true }
        if bytes.starts(with: [73, 73, 42, 0]) || bytes.starts(with: [77, 77, 0, 42]) || bytes.starts(with: [66, 77]) { return true }
        return bytes.count >= 12 && bytes.starts(with: Array("RIFF".utf8)) && Array(bytes[8..<12]) == Array("WEBP".utf8)
    }
}
#endif
