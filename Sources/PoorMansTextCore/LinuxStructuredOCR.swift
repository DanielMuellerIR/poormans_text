#if os(Linux)
import Foundation
import Glibc
import CPMTLinux

/// Docling erhält nur bereits gebundene PNG-Snapshots. Seine Ausgabe durchläuft
/// dieselbe inventartreue Projektion und denselben Renderer wie gespeicherte Daten.
enum LinuxStructuredOCR {
    struct Result {
        let page: StructuredOCRPage
        let diagnostics: [ConversionWarning]
    }
    // Erst nach unabhängiger Runtime-/Sandboxqualifikation vom Release-Writer setzen.
    private static let qualifiedRuntimeManifestSHA256: String? = "cd4673de443d7e2570d6c4c4666cecb4924e2ceaf22703cba2a273a544eface6"
    struct RuntimeFile: Decodable {
        let sha256: String
        let byteCount: Int
    }
    private struct RuntimeManifest: Decodable {
        let schemaVersion: Int
        let backend: String
        let qualifiedAdapterVersion: Int
        let files: [String: RuntimeFile]
    }
    struct Binding: Decodable {
        let sourceSHA256: String
        let width: Int
        let height: Int
        let documentSHA256: String
        let dpiX: Double?
        let dpiY: Double?
    }
    static func runtimeDirectory() throws -> URL {
        guard let executable = Bundle.main.executableURL else {
            throw PlatformBackendUnavailable("approved structured OCR runtime")
        }
        let root = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("structured-ocr", isDirectory: true)
        try validateRuntime(root)
        return root
    }
    static func validateRuntime(_ root: URL) throws {
        guard let expected = qualifiedRuntimeManifestSHA256 else {
            throw PlatformBackendUnavailable("qualified structured OCR runtime")
        }
        do {
            let rootFD = pmt_process_open_directory(root.path)
            guard rootFD >= 0 else { throw invalidBinding() }
            defer { close(rootFD) }
            var rootInfo = stat()
            guard fstat(rootFD, &rootInfo) == 0 else { throw invalidBinding() }
            let manifest = try VerifiedFile.openMember(named: "runtime-manifest.json", in: rootFD,
                sourceURL: root.appendingPathComponent("runtime-manifest.json"), failure: { _ in invalidBinding() }) { file in
                guard file.isRegularFile, file.info.st_nlink == 1, file.info.st_dev == rootInfo.st_dev,
                      file.info.st_size >= 0, file.info.st_size <= 8 * 1024 * 1024 else { throw invalidBinding() }
                var bytes = Data()
                _ = try file.readChunks(maximumBytes: 8 * 1024 * 1024, chunkSize: 65_536,
                    budgetExceeded: { invalidBinding() }) { bytes.append(contentsOf: $0); return true }
                var after = stat()
                guard fstat(file.descriptor, &after) == 0, sameInventoryObject(file.info, after) else { throw invalidBinding() }
                return bytes
            }
            guard ConversionFileFingerprint.digest(manifest) == expected else { throw invalidBinding() }
            try JSONStructurePreflight.validate(
                manifest, limits: .init(depth: 8, nodes: 500_000, keyBytes: 4096),
                documentName: "OCR runtime manifest")
            let value = try JSONDecoder().decode(RuntimeManifest.self, from: manifest)
            guard value.schemaVersion == 1, value.backend == "docling",
                value.qualifiedAdapterVersion == 1,
                !value.files.isEmpty, value.files.count <= 32_768
            else { throw invalidBinding() }
            try validateInventory(descriptor: rootFD, root: root, files: value.files,
                manifest: RuntimeFile(sha256: expected, byteCount: manifest.count))
            guard
                FileManager.default.isExecutableFile(
                    atPath: root.appendingPathComponent("bin/python3.12").path)
            else { throw invalidBinding() }
        } catch {
            try ConversionExecution.check()
            throw PlatformBackendUnavailable("qualified structured OCR runtime")
        }
    }
    static func validateInventory(_ root: URL, files: [String: RuntimeFile], manifest: RuntimeFile? = nil) throws {
        let descriptor = pmt_process_open_directory(root.path)
        guard descriptor >= 0 else { throw invalidRuntimeInventory() }
        defer { close(descriptor) }
        try validateInventory(descriptor: descriptor, root: root, files: files, manifest: manifest)
    }
    private static func sameInventoryObject(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
            && a.st_size == b.st_size && a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec
            && a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec
    }
    static func validateInventory(descriptor: Int32, root: URL, files: [String: RuntimeFile], manifest: RuntimeFile?) throws {
        guard !files.isEmpty, files.count <= 32_768 else { throw invalidRuntimeInventory() }
        var expected = files
        if let manifest {
            guard expected["runtime-manifest.json"] == nil else { throw invalidRuntimeInventory() }
            expected["runtime-manifest.json"] = manifest
        }
        var directories = Set<String>()
        var total = 0
        for (relative, file) in expected {
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard relative.utf8.count <= 4096, !relative.utf8.contains(0), !parts.isEmpty, parts.count <= 64,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
                      && !$0.contains("\\") && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }),
                  file.byteCount >= 0, file.byteCount <= 4 * 1024 * 1024 * 1024 - total else { throw invalidRuntimeInventory() }
            total += file.byteCount
            for length in 1..<parts.count {
                directories.insert(parts.prefix(length).joined(separator: "/"))
                guard directories.count <= 65_536 else { throw invalidRuntimeInventory() }
            }
        }
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { throw invalidRuntimeInventory() }
        var seenFiles = Set<String>()
        var seenDirectories = Set<String>()
        func walk(_ fd: Int32, prefix: String, depth: Int) throws {
            try ConversionExecution.check()
            guard depth <= 64 else { throw invalidRuntimeInventory() }
            var beforeDirectory = stat()
            guard fstat(fd, &beforeDirectory) == 0, beforeDirectory.st_dev == rootInfo.st_dev else { throw invalidRuntimeInventory() }
            // dup würde den Verzeichnisoffset des Aufrufers mitbenutzen.
            let duplicate = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard duplicate >= 0 else { throw invalidRuntimeInventory() }
            guard let stream = fdopendir(duplicate) else { close(duplicate); throw invalidRuntimeInventory() }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let pointer = readdir(stream) else {
                    guard errno == 0 else { throw invalidRuntimeInventory() }
                    break
                }
                var entry = pointer.pointee
                let capacity = MemoryLayout.size(ofValue: entry.d_name)
                let name = withUnsafePointer(to: &entry.d_name) { value in
                    value.withMemoryRebound(to: CChar.self, capacity: capacity) {
                        String(validatingCString: $0)
                    }
                }
                guard let name else { throw invalidRuntimeInventory() }
                if name == "." || name == ".." { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                guard relative.utf8.count <= 4096, depth < 64 else { throw invalidRuntimeInventory() }
                var before = stat()
                guard fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0, before.st_dev == rootInfo.st_dev else { throw invalidRuntimeInventory() }
                switch before.st_mode & S_IFMT {
                case S_IFDIR:
                    guard directories.contains(relative), seenDirectories.insert(relative).inserted else { throw invalidRuntimeInventory() }
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw invalidRuntimeInventory() }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, sameInventoryObject(before, opened) else { throw invalidRuntimeInventory() }
                    try walk(child, prefix: relative, depth: depth + 1)
                case S_IFREG:
                    guard let record = expected[relative], before.st_nlink == 1,
                          seenFiles.insert(relative).inserted else { throw invalidRuntimeInventory() }
                    try VerifiedFile.openMember(named: name, in: fd, sourceURL: root.appendingPathComponent(relative),
                        failure: { _ in invalidRuntimeInventory() }) { file in
                        guard file.isRegularFile, file.info.st_nlink == 1, sameInventoryObject(before, file.info),
                              file.info.st_size == record.byteCount else { throw invalidRuntimeInventory() }
                        let digest = try ConversionFileFingerprint.read(file)
                        var after = stat()
                        guard digest.byteCount == record.byteCount, digest.sha256 == record.sha256,
                              fstat(file.descriptor, &after) == 0, sameInventoryObject(file.info, after) else { throw invalidRuntimeInventory() }
                    }
                default: throw invalidRuntimeInventory()
                }
            }
            var afterDirectory = stat()
            guard fstat(fd, &afterDirectory) == 0, sameInventoryObject(beforeDirectory, afterDirectory) else { throw invalidRuntimeInventory() }
        }
        try walk(descriptor, prefix: "", depth: 0)
        guard seenFiles == Set(expected.keys), seenDirectories == directories else { throw invalidRuntimeInventory() }
    }
    private static func invalidRuntimeInventory() -> ConversionError {
        .fileSystemFailure("the structured OCR runtime inventory is invalid or changed")
    }
    static func recognize(pngURL: URL, languages: [String]) throws -> Result {
        try ConversionExecution.check()
        let runtime = try runtimeDirectory()
        let selected = try LinuxOCR.resolveLanguages(
            languages, available: LinuxOCR.availableLanguages())
        let helper = try LinuxBackendResources.script(named: "structured_ocr")
        return try OCRConcurrencyGate.shared.withPermit {
            try LinuxBackendWorkDirectory.withTemporaryDirectory { directory in
                let source = directory.appendingPathComponent("source.png")
                try VerifiedFileStaging.stage(
                    from: pngURL, to: source, maximumBytes: 256 * 1024 * 1024,
                    describedAs: "the structured OCR raster", followSourceSymlink: false)
                let bytes = try VerifiedFileStaging.contents(
                    of: source, maximumBytes: 256 * 1024 * 1024,
                    describedAs: "the structured OCR raster")
                let dimensions = try dimensions(bytes)
                let hash = ConversionFileFingerprint.digest(bytes)
                let output = directory.appendingPathComponent("document.json")
                let languageJSON = String(decoding: try JSONEncoder().encode(selected), as: UTF8.self)
                // Python bleibt unter seinem gebundenen Runtimeprefix; /pmt/tool
                // würde die relocierbare Standardbibliothek unauffindbar machen.
                let result = try ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c", "exec \"$1/bin/python3.12\" -I \"$2\" \"$1\" \"$3\" \"$4\" \"$5\"",
                        "pmt-structured-ocr",
                        runtime.path, helper.path, source.path, languageJSON, output.path,
                    ],
                    currentDirectory: directory, captureStandardOutput: true,
                    timeout: ConversionExecution.current?.processTimeout ?? 120,
                    maximumCapturedBytes: 8 * 1024 * 1024,
                    readOnlyPaths: [runtime, helper], writeScope: directory)
                if result.status == 69 {
                    throw PlatformBackendUnavailable("local structured OCR models and runtime")
                }
                guard result.status == 0 else {
                    throw ConversionError.fileSystemFailure(
                        "structured local OCR failed: \(result.standardError)")
                }
                let bindingData = Data(result.standardOutput.utf8)
                guard bindingData.count <= 4096 else { throw invalidBinding() }
                try JSONStructurePreflight.validate(
                    bindingData, limits: .init(depth: 4, nodes: 32, keyBytes: 128),
                    documentName: "OCR raster binding")
                let binding = try JSONDecoder().decode(Binding.self, from: bindingData)
                let verifiedDocument = directory.appendingPathComponent("verified-document.json")
                try VerifiedFileStaging.stage(
                    from: output, to: verifiedDocument, maximumBytes: 8 * 1024 * 1024,
                    describedAs: "the structured OCR document", followSourceSymlink: false)
                let document = try VerifiedFileStaging.contents(
                    of: verifiedDocument, maximumBytes: 8 * 1024 * 1024,
                    describedAs: "the structured OCR document")
                guard binding.sourceSHA256 == hash, binding.width == dimensions.width,
                    binding.height == dimensions.height,
                    binding.dpiX == dimensions.dpiX, binding.dpiY == dimensions.dpiY,
                    binding.documentSHA256 == ConversionFileFingerprint.digest(document),
                    try ConversionFileFingerprint.read(source).sha256 == hash
                else { throw invalidBinding() }
                return try project(document, width: dimensions.width, height: dimensions.height,
                    dpiX: dimensions.dpiX, dpiY: dimensions.dpiY)
            }
        }
    }
    static func project(_ data: Data, width: Int, height: Int, dpiX: Double? = nil, dpiY: Double? = nil) throws -> Result {
        let projected = try DoclingDocumentProjection.parse(data)
        // Die physische Seitengröße folgt den tatsächlich validierten pHYs-
        // Werten beider PNG-Achsen, auch nach gerundetem Downscale.
        guard (dpiX == nil) == (dpiY == nil), width > 0, height > 0,
              [dpiX, dpiY].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10_000 }) else { throw invalidBinding() }
        let expectedWidth = Double(width) * (dpiX.map { 72 / $0 } ?? 1)
        let expectedHeight = Double(height) * (dpiY.map { 72 / $0 } ?? 1)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = root["pages"] as? [String: Any], let pageRecord = pages["1"] as? [String: Any],
              let size = pageRecord["size"] as? [String: Any], let w = size["width"] as? Double,
              let h = size["height"] as? Double,
              abs(w - expectedWidth) <= max(0.000001, expectedWidth * 0.000001),
              abs(h - expectedHeight) <= max(0.000001, expectedHeight * 0.000001) else { throw invalidBinding() }
        let page = try StructuredOCRRendering.render(projected.recognition)
        var diagnostics = [
            ConversionWarning(
                code: "ocr.structuredApplied",
                message:
                    "Structured local OCR was projected from the verified raster without replacing original assets.",
                kind: .information),
            ConversionWarning(
                code: "ocr.structuredApproximation",
                message:
                    "Structured OCR is an approximation. Recognized text and table structure can differ from the source; inspect the retained original.",
                kind: .approximation),
        ]
        if page.flattenedSpans {
            diagnostics.append(
                ConversionWarning(
                    code: "ocr.tableSpansFlattened",
                    message:
                        "Merged OCR cells are written once at their upper-left position; covered cells remain empty."
                ))
        }
        return Result(page: page, diagnostics: diagnostics)
    }
    static func dimensions(_ data: Data) throws -> (width: Int, height: Int, dpiX: Double?, dpiY: Double?) {
        guard data.count >= 24, data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw RasterImageValidationError.invalid
        }
        func integer(_ offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
        }
        let width = integer(16)
        let height = integer(20)
        guard width > 0, height > 0, height <= 16_000_000, width <= 16_000_000 / height else {
            throw RasterImageValidationError.exceedsLimits
        }
        var info = pmt_image_info()
        let status = data.withUnsafeBytes {
            pmt_validate_png($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &info)
        }
        guard status == PMT_IMAGE_OK, Int(info.width) == width, Int(info.height) == height else {
            throw RasterImageValidationError.invalid
        }
        var dpiX: Double?
        var dpiY: Double?
        var sawResolution = false
        var sawPixels = false
        var cursor = 8
        while cursor <= data.count - 12 {
            let length = integer(cursor)
            guard length <= data.count - cursor - 12 else { throw RasterImageValidationError.invalid }
            let type = data[(cursor + 4)..<(cursor + 8)]
            if type.elementsEqual([73, 68, 65, 84]) { sawPixels = true }
            if type.elementsEqual([112, 72, 89, 115]) {
                guard !sawResolution, !sawPixels, length == 9 else { throw RasterImageValidationError.invalid }
                sawResolution = true
                let x = integer(cursor + 8), y = integer(cursor + 12), unit = data[cursor + 16]
                guard unit <= 1, x > 0, y > 0 else { throw RasterImageValidationError.invalid }
                if unit == 1 {
                    let xDPI = Double(x) * 0.0254, yDPI = Double(y) * 0.0254
                    guard xDPI <= 10_000, yDPI <= 10_000 else { throw RasterImageValidationError.invalid }
                    dpiX = xDPI; dpiY = yDPI
                } else if x != y { throw RasterImageValidationError.invalid }
            }
            cursor += length + 12
        }
        return (width, height, dpiX, dpiY)
    }
    private static func invalidBinding() -> ConversionError {
        .fileSystemFailure("the structured OCR result does not match its verified raster")
    }
}
#endif
