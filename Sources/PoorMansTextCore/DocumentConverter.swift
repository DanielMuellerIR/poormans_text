import Foundation

/// Formatneutrale Orchestrierung für Erkennung, Adapterwahl und Veröffentlichung.
public struct DocumentConverter: Sendable {
    private let adapters: [InputFormat: any DocumentConversionAdapter]

    public init() {
        self.init(adapters: [RichTextAdapter()])
    }

    init(adapters: [any DocumentConversionAdapter]) {
        var registry = [InputFormat: any DocumentConversionAdapter]()
        for adapter in adapters {
            for format in adapter.supportedFormats {
                precondition(registry[format] == nil, "More than one adapter handles \(format.rawValue)")
                registry[format] = adapter
            }
        }
        self.adapters = registry
    }

    public var supportedFormats: Set<InputFormat> {
        Set(adapters.keys)
    }

    /// Erkennt das Format erneut aus der Quelle und beschreibt bekannte Verluste.
    public func inspect(_ requestedInputURL: URL) throws -> InputInspection {
        let inputURL = requestedInputURL.standardizedFileURL
        let format = try detectFormat(at: inputURL)
        guard let adapter = adapters[format] else {
            throw ConversionError.inputIsNotRichText(inputURL)
        }
        return InputInspection(
            inputURL: inputURL,
            format: format,
            expectedWarnings: adapter.expectedWarnings(for: inputURL, format: format)
        )
    }

    public func detectFormat(at requestedInputURL: URL) throws -> InputFormat {
        try detectInputFormat(at: requestedInputURL.standardizedFileURL)
    }

    public func convert(
        _ request: ConversionRequest,
        progress: ConversionProgressHandler? = nil
    ) throws -> ConversionResult {
        progress?(ConversionProgress(phase: .detectingInput))
        let inputURL = request.inputURL.standardizedFileURL
        let format = try detectInputFormat(at: inputURL)

        progress?(ConversionProgress(phase: .preparingOutput, format: format))
        let destination = resolveDestination(for: request, inputURL: inputURL)
        let fileManager = FileManager.default
        try validateOutput(destination.url, inputURL: inputURL, fileManager: fileManager)

        let outputParent = destination.url.deletingLastPathComponent()
        let temporaryRoot = outputParent.appendingPathComponent(
            ".poormans-text-\(UUID().uuidString).tmp",
            isDirectory: true
        )
        let workDirectory = temporaryRoot.appendingPathComponent("work", isDirectory: true)
        let stagedOutput = temporaryRoot.appendingPathComponent("result", isDirectory: true)

        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagedOutput, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        guard let adapter = adapters[format] else {
            throw ConversionError.inputIsNotRichText(inputURL)
        }
        progress?(ConversionProgress(phase: .converting, format: format))
        let stagedResult = try adapter.convert(
            AdapterConversionContext(
                inputURL: inputURL,
                format: format,
                workDirectory: workDirectory,
                stagedOutputDirectory: stagedOutput,
                options: request.options
            )
        )

        let markdownRelativePath = try validateRelativePath(stagedResult.markdownRelativePath)
        let assetRelativePaths = try stagedResult.assetRelativePaths.map(validateRelativePath)
        let stagedMarkdown = stagedOutput.appendingPathComponent(markdownRelativePath)
        guard isRegularFile(stagedMarkdown, fileManager: fileManager) else {
            throw ConversionError.fileSystemFailure("adapter produced no Markdown file")
        }
        for assetRelativePath in assetRelativePaths {
            let stagedAsset = stagedOutput.appendingPathComponent(assetRelativePath)
            guard isRegularFile(stagedAsset, fileManager: fileManager) else {
                throw ConversionError.fileSystemFailure("adapter reported a missing asset")
            }
        }

        progress?(ConversionProgress(phase: .publishing, format: format))
        try publish(
            stagedOutput,
            to: destination.url,
            inputURL: inputURL,
            fileManager: fileManager
        )

        let result = ConversionResult(
            inputURL: inputURL,
            format: format,
            outputDirectory: destination.url,
            markdownFile: destination.url.appendingPathComponent(markdownRelativePath),
            assets: assetRelativePaths.map { destination.url.appendingPathComponent($0) },
            outputLifetime: destination.lifetime,
            diagnostics: stagedResult.warnings
        )
        progress?(ConversionProgress(phase: .finished, format: format))
        return result
    }

    public static func defaultOutputDirectory(for inputURL: URL) -> URL {
        let inputURL = inputURL.standardizedFileURL
        return inputURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                inputURL.deletingPathExtension().lastPathComponent + "-markdown",
                isDirectory: true
            )
    }

    private func detectInputFormat(at inputURL: URL) throws -> InputFormat {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
            throw ConversionError.inputDoesNotExist(inputURL)
        }

        if isDirectory.boolValue {
            let rtfURL = inputURL.appendingPathComponent("TXT.rtf")
            var rtfIsDirectory: ObjCBool = false
            let hasRTFFile = fileManager.fileExists(atPath: rtfURL.path, isDirectory: &rtfIsDirectory)
                && !rtfIsDirectory.boolValue

            if hasRTFFile, try hasRTFHeader(at: rtfURL) {
                return .rtfd
            }
            if inputURL.pathExtension.lowercased() == "rtfd" {
                let reason = hasRTFFile ? "TXT.rtf has no RTF header" : "TXT.rtf is missing"
                throw ConversionError.invalidRichText(inputURL, reason: reason)
            }
            throw ConversionError.inputIsNotRichText(inputURL)
        }

        if try hasRTFHeader(at: inputURL) {
            return .rtf
        }
        if inputURL.pathExtension.lowercased() == "rtf" {
            throw ConversionError.invalidRichText(inputURL, reason: "the RTF header is missing")
        }
        throw ConversionError.inputIsNotRichText(inputURL)
    }

    private func hasRTFHeader(at url: URL) throws -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = [UInt8](try handle.read(upToCount: 32) ?? Data())
            let signature = [UInt8](#"{\rtf"#.utf8)
            guard bytes.starts(with: signature) else {
                return false
            }

            // `\rtf` ist ein Steuerwort mit verpflichtender Versionszahl.
            // Ohne Zifferngrenze würde etwa `\rtfake` als Dokument gelten.
            let versionStart = signature.count
            return versionStart < bytes.count && bytes[versionStart].isASCIIDigit
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
    }

    private func resolveDestination(
        for request: ConversionRequest,
        inputURL: URL
    ) -> ResolvedDestination {
        switch request.destination {
        case .adjacentToInput:
            return ResolvedDestination(
                url: Self.defaultOutputDirectory(for: inputURL),
                lifetime: .persistent
            )
        case .directory(let url):
            return ResolvedDestination(url: url.standardizedFileURL, lifetime: .persistent)
        case .temporary:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PoorMansTextImport-\(UUID().uuidString)",
                isDirectory: true
            )
            return ResolvedDestination(url: url, lifetime: .temporary)
        }
    }

    private func validateOutput(
        _ outputURL: URL,
        inputURL: URL,
        fileManager: FileManager
    ) throws {
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw ConversionError.outputAlreadyExists(outputURL)
        }

        let resolvedInputPath = inputURL.resolvingSymlinksInPath().path + "/"
        let resolvedOutputPath = outputURL.resolvingSymlinksInPath().path + "/"
        guard !resolvedOutputPath.hasPrefix(resolvedInputPath) else {
            throw ConversionError.outputInsideInput(outputURL)
        }

        let parent = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ConversionError.outputParentDoesNotExist(parent)
        }
    }

    private func publish(
        _ stagedOutput: URL,
        to outputURL: URL,
        inputURL: URL,
        fileManager: FileManager
    ) throws {
        // Die zweite Prüfung schließt das Zeitfenster zwischen Vorbereitung und
        // Veröffentlichung, ohne ein inzwischen angelegtes Ziel zu überschreiben.
        try validateOutput(outputURL, inputURL: inputURL, fileManager: fileManager)
        do {
            try fileManager.moveItem(at: stagedOutput, to: outputURL)
        } catch {
            if fileManager.fileExists(atPath: outputURL.path) {
                throw ConversionError.outputAlreadyExists(outputURL)
            }
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
    }

    private func validateRelativePath(_ path: String) throws -> String {
        let components = NSString(string: path).pathComponents
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !components.contains("..") else {
            throw ConversionError.fileSystemFailure("adapter produced an unsafe output path")
        }
        return path
    }

    private func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private struct ResolvedDestination {
        let url: URL
        let lifetime: ConversionOutputLifetime
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool {
        self >= 0x30 && self <= 0x39
    }
}

protocol DocumentConversionAdapter: Sendable {
    var supportedFormats: Set<InputFormat> { get }

    func expectedWarnings(for inputURL: URL, format: InputFormat) -> [ConversionWarning]
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult
}

struct AdapterConversionContext: Sendable {
    let inputURL: URL
    let format: InputFormat
    let workDirectory: URL
    let stagedOutputDirectory: URL
    let options: ConversionOptions
}

struct StagedConversionResult: Sendable {
    let markdownRelativePath: String
    let assetRelativePaths: [String]
    let warnings: [ConversionWarning]
}
