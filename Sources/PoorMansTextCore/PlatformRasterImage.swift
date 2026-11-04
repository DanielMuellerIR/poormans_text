import Foundation
#if os(Linux)
import CPMTLinux
#else
import ImageIO
import UniformTypeIdentifiers
#endif

struct RasterImageInfo: Equatable, Sendable {
    let fileExtension: String
    let width: Int
    let height: Int
    let frameCount: Int
}

enum RasterImageValidationError: LocalizedError {
    case unavailable
    case invalid
    case exceedsLimits
    case insufficientMemory

    var errorDescription: String? {
        switch self {
        case .unavailable: "image format is not supported by the local image decoder"
        case .invalid: "image data could not be decoded"
        case .exceedsLimits: "image exceeds the local decoder size limits"
        case .insufficientMemory: "image could not be decoded within available memory"
        }
    }
}

enum RasterImageBackend {
    static func validate(_ data: Data) throws -> RasterImageInfo {
        guard data.count <= 256 * 1_024 * 1_024 else {
            throw RasterImageValidationError.exceedsLimits
        }
        #if os(Linux)
        var info = pmt_image_info()
        let status = data.withUnsafeBytes { bytes in
            pmt_validate_png(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &info)
        }
        switch status {
        case PMT_IMAGE_OK:
            return RasterImageInfo(fileExtension: "png", width: Int(info.width),
                                   height: Int(info.height), frameCount: Int(info.frame_count))
        case PMT_IMAGE_UNSUPPORTED: throw RasterImageValidationError.unavailable
        case PMT_IMAGE_TOO_LARGE: throw RasterImageValidationError.exceedsLimits
        case PMT_IMAGE_OUT_OF_MEMORY: throw RasterImageValidationError.insufficientMemory
        default: throw RasterImageValidationError.invalid
        }
        #else
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source),
              let fileExtension = UTType(type as String)?.preferredFilenameExtension,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.dataProvider?.data != nil else {
            throw RasterImageValidationError.invalid
        }
        return RasterImageInfo(fileExtension: fileExtension, width: width, height: height,
                               frameCount: CGImageSourceGetCount(source))
        #endif
    }
}
