import Foundation

/// Formatneutrale Orchestrierung für Erkennung, Adapterwahl und Veröffentlichung.
public struct DocumentConverter: Sendable {
    private let adapters: [any DocumentConversionAdapter]

    public init() {
        self.init(adapters: [
            RichTextAdapter(),
            WordProcessingPackageAdapter(),
            LegacyWordAdapter(),
        ])
    }

    init(adapters: [any DocumentConversionAdapter]) {
        var registeredFormats = Set<InputFormat>()
        for adapter in adapters {
            for format in adapter.supportedFormats {
                precondition(
                    registeredFormats.insert(format).inserted,
                    "More than one adapter handles \(format.rawValue)"
                )
            }
        }
        self.adapters = adapters
    }

    public var supportedFormats: Set<InputFormat> {
        Set(adapters.flatMap(\.supportedFormats))
    }

    /// Erkennt das Format erneut aus der Quelle und beschreibt bekannte Verluste.
    public func inspect(_ requestedInputURL: URL) throws -> InputInspection {
        let inputURL = requestedInputURL.standardizedFileURL
        let detected = try detectInput(at: inputURL)
        return InputInspection(
            inputURL: inputURL,
            format: detected.inspection.format,
            expectedWarnings: detected.inspection.expectedWarnings
        )
    }

    public func detectFormat(at requestedInputURL: URL) throws -> InputFormat {
        try detectInput(at: requestedInputURL.standardizedFileURL).inspection.format
    }

    public func convert(
        _ request: ConversionRequest,
        progress: ConversionProgressHandler? = nil
    ) throws -> ConversionResult {
        progress?(ConversionProgress(phase: .detectingInput))
        let inputURL = request.inputURL.standardizedFileURL
        let detected = try detectInput(at: inputURL)
        let format = detected.inspection.format

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

        progress?(ConversionProgress(phase: .converting, format: format))
        let stagedResult = try detected.adapter.convert(
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

    private func detectInput(at inputURL: URL) throws -> DetectedInput {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputDoesNotExist(inputURL)
        }

        var matches = [DetectedInput]()
        var invalidInputs = [InvalidDetectedInput]()
        for adapter in adapters {
            switch try adapter.inspectInput(at: inputURL) {
            case .noMatch:
                continue
            case .match(let inspection):
                precondition(
                    adapter.supportedFormats.contains(inspection.format),
                    "Adapter inspected unsupported format \(inspection.format.rawValue)"
                )
                matches.append(DetectedInput(inspection: inspection, adapter: adapter))
            case .invalid(let format, let priority, let reason):
                precondition(
                    adapter.supportedFormats.contains(format),
                    "Adapter rejected unsupported format \(format.rawValue)"
                )
                invalidInputs.append(
                    InvalidDetectedInput(format: format, priority: priority, reason: reason)
                )
            }
        }

        if !matches.isEmpty {
            let highestPriority = matches.map(\.inspection.priority).max() ?? 0
            let preferred = matches.filter { $0.inspection.priority == highestPriority }
            guard preferred.count == 1, let detected = preferred.first else {
                throw ConversionError.ambiguousInput(
                    inputURL,
                    formats: preferred.map(\.inspection.format)
                )
            }
            return detected
        }

        if let invalid = invalidInputs.max(by: { $0.priority < $1.priority }) {
            throw ConversionError.invalidInput(
                inputURL,
                format: invalid.format,
                reason: invalid.reason
            )
        }

        throw ConversionError.unsupportedInput(inputURL)
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

    private struct DetectedInput: Sendable {
        let inspection: AdapterInputInspection
        let adapter: any DocumentConversionAdapter
    }

    private struct InvalidDetectedInput {
        let format: InputFormat
        let priority: Int
        let reason: String
    }
}

protocol DocumentConversionAdapter: Sendable {
    var supportedFormats: Set<InputFormat> { get }

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult
}

enum AdapterInputDetection: Sendable {
    case noMatch
    case match(AdapterInputInspection)
    case invalid(format: InputFormat, priority: Int, reason: String)
}

struct AdapterInputInspection: Sendable {
    let format: InputFormat
    let priority: Int
    let expectedWarnings: [ConversionWarning]
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
