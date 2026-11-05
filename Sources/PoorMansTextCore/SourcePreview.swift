import Foundation

public enum SourcePreviewSelection: Sendable {
    case page(Int)
    case frame(Int)

    var index: Int { switch self { case .page(let index), .frame(let index): index } }
    var kind: String { switch self { case .page: "page"; case .frame: "frame" } }
}

/// Passive Vorschau genau des durch sourceIdentity belegten Quelldatenstroms.
public struct SourcePreview: Encodable, Sendable {
    public let sourceIdentity: ConversionSourceIdentity
    public let kind: String
    public let index: Int
    public let count: Int
    public let width: Int
    public let height: Int
    public let png: Data
    public let byteCount: Int
    public let sha256: String
    public let diagnostics: [ConversionWarning]

    static let maximumSourceBytes = 128 * 1024 * 1024
    static let maximumPNGBytes = 5 * 1024 * 1024
}

#if os(Linux)
enum LinuxSourcePreview {
    private struct Manifest: Decodable {
        let kind: String
        let index: Int
        let count: Int
        let width: Int
        let height: Int
        let downscaled: Bool
    }

    static func render(_ inputURL: URL, selection: SourcePreviewSelection) throws -> SourcePreview {
        do { return try renderSnapshot(inputURL, selection: selection) }
        catch let error as VerifiedFileStaging.StagingError {
            switch error.kind {
            case .source: throw ConversionError.invalidInput(inputURL, format: selection.kind == "page" ? .pdf : .image, reason: error.reason)
            case .destination: throw ConversionError.fileSystemFailure(error.reason)
            }
        }
    }

    private static func renderSnapshot(_ inputURL: URL, selection: SourcePreviewSelection) throws -> SourcePreview {
        guard (1...1000).contains(selection.index) else {
            throw ConversionError.invalidInput(inputURL, format: selection.kind == "page" ? .pdf : .image, reason: "the source preview index must be between 1 and 1000")
        }
        try LinuxPathValidation.validate(inputURL)
        let resolved = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        return try LinuxBackendWorkDirectory.withTemporaryDirectory { sourceDirectory in
            let snapshot = sourceDirectory.appendingPathComponent("source")
            try VerifiedFileStaging.stage(from: resolved, to: snapshot,
                maximumBytes: SourcePreview.maximumSourceBytes, describedAs: "the source preview input")
            let fingerprint = try ConversionFileFingerprint.read(snapshot)
            let identity = ConversionSourceIdentity(name: inputURL.lastPathComponent, sha256: fingerprint.sha256,
                byteCount: fingerprint.byteCount, unavailableReason: nil)
            return try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
                let result: ProcessResult
                switch selection {
                case .page:
                    result = try LinuxBackendResources.runPython(script: "poppler",
                        arguments: ["preview", snapshot.path, String(selection.index)], in: directory, readOnlyPaths: [snapshot])
                case .frame:
                    result = try LinuxRasterBackend.preview(source: snapshot, index: selection.index, directory: directory)
                }
                try ConversionExecution.check()
                if result.status == 69 { throw PlatformBackendUnavailable("local source preview renderer") }
                if result.status == 74 { throw ConversionError.fileSystemFailure(result.standardError) }
                guard result.status == 0 else {
                    throw ConversionError.invalidInput(inputURL, format: selection.kind == "page" ? .pdf : .image,
                        reason: result.standardError.isEmpty ? "the local source preview failed" : result.standardError)
                }
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(result.standardOutput.utf8))
                guard manifest.kind == selection.kind, manifest.index == selection.index,
                      (1...1000).contains(manifest.count), manifest.index <= manifest.count,
                      (1...1024).contains(manifest.width), (1...1024).contains(manifest.height) else {
                    throw ConversionError.fileSystemFailure("the source preview manifest is invalid")
                }
                let png = try VerifiedFileStaging.withVerifiedSource(at: directory.appendingPathComponent("preview.png"),
                    maximumBytes: SourcePreview.maximumPNGBytes, describedAs: "the source preview PNG", followSourceSymlink: false) { file, _ in
                        var data = Data()
                        _ = try file.readChunks(maximumBytes: SourcePreview.maximumPNGBytes, chunkSize: 262_144,
                            budgetExceeded: { RasterImageValidationError.exceedsLimits }) { data.append(contentsOf: $0); return true }
                        return data
                    }
                // Vor dem vollständigen libpng-Decode auch die engere Vorschaugrenze prüfen.
                guard png.count >= 33, Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
                      Array(png[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { throw RasterImageValidationError.invalid }
                func dimension(_ offset: Int) -> Int { png[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) } }
                guard dimension(16) == manifest.width, dimension(20) == manifest.height else { throw RasterImageValidationError.invalid }
                let decoded = try RasterImageBackend.validate(png)
                guard decoded.fileExtension == "png", decoded.frameCount == 1,
                      decoded.width == manifest.width, decoded.height == manifest.height else { throw RasterImageValidationError.invalid }
                try ConversionExecution.check()
                var diagnostics = [ConversionWarning(code: "preview.passiveRaster",
                    message: "This bounded source raster is passive. Source metadata is removed, transparent pixels appear on white, and interactive source actions are unavailable.", kind: .information)]
                if selection.kind == "page" {
                    diagnostics.append(ConversionWarning(code: "preview.annotationsOmitted",
                        message: "The source preview omits annotation appearances and may differ from a full PDF viewer.", kind: .approximation))
                }
                if manifest.downscaled {
                    diagnostics.append(ConversionWarning(code: "preview.downscaled",
                        message: "The source preview was downscaled to at most 1024 pixels per edge.", kind: .approximation))
                }
                return SourcePreview(sourceIdentity: identity, kind: manifest.kind, index: manifest.index,
                    count: manifest.count, width: manifest.width, height: manifest.height, png: png,
                    byteCount: png.count, sha256: ConversionFileFingerprint.digest(png), diagnostics: diagnostics)
            }
        }
    }
}
#endif
