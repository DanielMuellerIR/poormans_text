#if os(Linux)
import Foundation

struct LinuxRasterInspection: Decodable {
    let fileExtension: String
    let width: Int
    let height: Int
    let frameCount: Int
    let frames: [LinuxRasterFrame]

    func validated() throws -> Self {
        guard ["png", "jpg", "gif", "tiff", "bmp", "webp", "heic"].contains(fileExtension),
              (1...1000).contains(frameCount), frames.count == frameCount,
              width > 0, height > 0,
              frames.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.height <= 64_000_000 && $0.width <= 64_000_000 / $0.height }) else {
            throw RasterImageValidationError.invalid
        }
        return self
    }

    var imageInfo: RasterImageInfo {
        RasterImageInfo(fileExtension: fileExtension, width: width, height: height, frameCount: frameCount)
    }
}

struct LinuxRasterFrame: Decodable {
    let width: Int
    let height: Int
    let ocrWidth: Int?
    let ocrHeight: Int?
    let downscaled: Bool?
}

enum LinuxRasterBackend {
    static func isAvailable() -> Bool {
        (try? LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let result = try runRaster(arguments: ["capabilities"], in: directory)
            return result.status == 0
        }) ?? false
    }

    static func isHEICAvailable() -> Bool {
        (try? LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let result = try runRaster(arguments: ["capabilities", "--probe-heic"], in: directory,
                timeout: min(10, ConversionExecution.current?.processTimeout ?? 10))
            guard result.status == 0,
                  let value = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any] else { return false }
            return value["heic"] as? Bool == true
        }) ?? false
    }

    private static func runRaster(arguments: [String], in directory: URL, input: URL? = nil, timeout: TimeInterval? = nil) throws -> ProcessResult {
        let heif = try? LinuxBackendResources.script(named: "heif")
        return try LinuxBackendResources.runPython(script: "raster",
            arguments: arguments + (heif.map { ["--heif-helper", $0.path] } ?? []), in: directory,
            readOnlyPaths: (heif.map { [$0] } ?? []) + (input.map { [$0] } ?? []), timeout: timeout)
    }

    static func preview(source: URL, index: Int, directory: URL) throws -> ProcessResult {
        try runRaster(arguments: ["preview", source.path, "--index", String(index)], in: directory, input: source)
    }

    static func inspect(_ data: Data) throws -> RasterImageInfo {
        guard data.count <= 256 * 1024 * 1024 else { throw RasterImageValidationError.exceedsLimits }
        return try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("source")
            try data.write(to: source)
            return try LinuxBackendWorkDirectory.withTemporaryDirectory { output in
                try run(source: source, directory: output, mode: "inspect").imageInfo
            }
        }
    }

    static func inspect(source: URL) throws -> LinuxRasterInspection {
        try withFrames(source: source, render: false) { inspection, _ in inspection }
    }

    static func withFrames<T>(source: URL, render: Bool,
                              _ body: (LinuxRasterInspection, URL) throws -> T) throws -> T {
        try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
            let snapshot = directory.appendingPathComponent("source")
            try VerifiedFileStaging.stage(from: source, to: snapshot, maximumBytes: 1_073_741_824,
                                           describedAs: "the image source")
            return try LinuxBackendWorkDirectory.withTemporaryDirectory { output in
                let inspection = try run(source: snapshot, directory: output, mode: render ? "frames" : "inspect")
                return try body(inspection, output)
            }
        }
    }

    private static func run(source: URL, directory: URL, mode: String) throws -> LinuxRasterInspection {
        let result = try runRaster(arguments: [mode, source.path], in: directory, input: source)
        if result.status == 69 { throw PlatformBackendUnavailable("local raster decoder (Python Pillow / HEIC libheif)") }
        if result.status == 74 { throw ConversionError.fileSystemFailure(result.standardError) }
        guard result.status == 0 else {
            throw ConversionError.invalidInput(source, format: .image,
                reason: result.standardError.isEmpty ? "the local raster decoder failed" : result.standardError)
        }
        guard let bytes = result.standardOutput.data(using: .utf8) else { throw RasterImageValidationError.invalid }
        return try JSONDecoder().decode(LinuxRasterInspection.self, from: bytes).validated()
    }
}
#endif
