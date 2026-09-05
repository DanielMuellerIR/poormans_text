import Foundation

public struct BatchConversionResult: Sendable {
    public let index: Int
    public let inputURL: URL
    public let outcome: Result<ConversionResult, any Error>
}

/// Index und Sequenz erlauben UI-Adaptern, parallel eintreffende Meldungen
/// eindeutig einem Dokument zuzuordnen. Der Callback läuft auf Worker-Threads.
public struct BatchConversionProgress: Sendable {
    public let sequence: Int
    public let index: Int
    public let inputURL: URL
    public let completed: Int
    public let total: Int
    public let running: [Int]
    public let documentProgress: ConversionProgress?
    public let result: BatchConversionResult?
}
public typealias BatchConversionProgressHandler = @Sendable (BatchConversionProgress) -> Void

/// Gemeinsame Batchgrenze für App und CLI. Alle Ziele werden vor jeglichem
/// mkdir und Workerstart gegen alle Quellen geprüft und in Eingabereihenfolge
/// reserviert. Maximal vier synchrone Dokumentkonvertierungen laufen zugleich.
public struct BatchConverter: Sendable {
    private let converter: DocumentConverter
    public init(converter: DocumentConverter = DocumentConverter()) { self.converter = converter }

    public func convert(
        _ requests: [ConversionRequest],
        jobs: Int = 1,
        outputRoots: [URL] = [],
        protecting additionalInputs: [URL] = [],
        cancellation: ConversionCancellationToken = ConversionCancellationToken(),
        processTimeout: TimeInterval? = nil,
        progress: BatchConversionProgressHandler? = nil
    ) throws -> [BatchConversionResult] {
        guard (1...4).contains(jobs) else { throw ConversionError.fileSystemFailure("batch parallelism must be between 1 and 4") }
        try cancellation.checkCancellation()
        var seenSources = Set<URL>()
        let sources = (requests.map(\.inputURL) + additionalInputs).filter { seenSources.insert($0.standardizedFileURL).inserted }
        let plan = try BatchOutputPlan(requests: requests, roots: outputRoots, sources: sources)
        try cancellation.checkCancellation()
        try plan.prepareRoots(cancellation)
        let state = State(count: requests.count)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "PoorMansText.Batch", qos: .userInitiated, attributes: .concurrent)
        for _ in 0..<min(jobs, requests.count) {
            group.enter()
            queue.async {
                defer { group.leave() }
                while let index = state.next() {
                    let request = plan.requests[index]
                    let result: BatchConversionResult
                    do {
                        try cancellation.checkCancellation()
                        if let error = plan.errors[index] { throw error }
                        state.started(index)
                        progress?(state.event(index: index, input: request.inputURL))
                        try cancellation.checkCancellation()
                        try plan.prepareParent(at: index)
                        let context = ConversionExecution.Context(cancellation: cancellation, progress: nil,
                            processTimeout: processTimeout, protectedInputs: plan.sources, plannedSources: plan.sourceSnapshots)
                        let converted = try ConversionExecution.$current.withValue(context) {
                            try converter.convert(request, progress: { value in
                                progress?(state.event(index: index, input: request.inputURL, document: value))
                            }, cancellation: cancellation, processTimeout: processTimeout)
                        }
                        result = BatchConversionResult(index: index, inputURL: request.inputURL, outcome: .success(converted))
                    } catch {
                        result = BatchConversionResult(index: index, inputURL: request.inputURL, outcome: .failure(error))
                    }
                    let finished = state.finished(result)
                    progress?(finished)
                }
            }
        }
        group.wait()
        return state.results()
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let count: Int
        var cursor = 0
        var sequence = 0
        var completed = 0
        var running = Set<Int>()
        var outcomes: [BatchConversionResult?]
        init(count: Int) { self.count = count; outcomes = Array(repeating: nil, count: count) }
        func next() -> Int? { lock.withLock { guard cursor < count else { return nil }; defer { cursor += 1 }; return cursor } }
        func started(_ index: Int) { lock.withLock { _ = running.insert(index) } }
        func event(index: Int, input: URL, document: ConversionProgress? = nil) -> BatchConversionProgress {
            lock.withLock {
                sequence += 1
                return BatchConversionProgress(sequence: sequence, index: index, inputURL: input, completed: completed,
                    total: count, running: running.sorted(), documentProgress: document, result: nil)
            }
        }
        func finished(_ result: BatchConversionResult) -> BatchConversionProgress {
            lock.withLock {
                outcomes[result.index] = result; running.remove(result.index); completed += 1; sequence += 1
                return BatchConversionProgress(sequence: sequence, index: result.index, inputURL: result.inputURL, completed: completed,
                    total: count, running: running.sorted(), documentProgress: nil, result: result)
            }
        }
        func results() -> [BatchConversionResult] { lock.withLock { outcomes.compactMap { $0 } } }
    }
}

/// Prüft auch den Fall, dass ein Ziel neben einer Datei INNERHALB eines anderen
/// Quelldokuments liegt. Unbekannte Volume-Eigenschaften werden konservativ wie
/// ein Dateisystem ohne Groß-/Kleinschreibungsunterscheidung behandelt.
enum BatchSourceProtection {
    static func validate(_ outputs: [URL], sources: [URL]) throws {
        let resolvedOutputs = outputs.map { ($0, $0.standardizedFileURL.resolvingSymlinksInPath().path) }
        for source in sources {
            let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
            let sensitive = (try? resolved.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == true
            let sourcePath = sensitive ? resolved.path : resolved.path.lowercased()
            for (output, resolvedOutput) in resolvedOutputs {
                let outputPath = sensitive ? resolvedOutput : resolvedOutput.lowercased()
                guard outputPath != sourcePath && !outputPath.hasPrefix(sourcePath + "/") else { throw ConversionError.outputInsideInput(output) }
            }
        }
    }
    static func reservationKey(_ url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var existing = resolved
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        let sensitive = (try? existing.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == true
        return sensitive ? resolved.path : resolved.path.lowercased()
    }
}

private struct BatchOutputPlan: Sendable {
    let requests: [ConversionRequest]
    let roots: [URL]
    let sources: [URL]
    let sourceSnapshots: [String: URL]
    let outputs: [URL?]
    let resolvedOutputs: [URL?]
    let errors: [Int: ConversionError]
    init(requests: [ConversionRequest], roots: [URL], sources: [URL]) throws {
        self.requests = requests; self.roots = roots
        var snapshots: [String: URL] = [:]
        for source in sources { snapshots[source.standardizedFileURL.path] = source.standardizedFileURL.resolvingSymlinksInPath() }
        sourceSnapshots = snapshots
        var seen = Set<URL>()
        self.sources = (sources + Array(snapshots.values)).filter { seen.insert($0.standardizedFileURL).inserted }
        outputs = requests.map { request in
            switch request.destination {
            case .adjacentToInput: return DocumentConverter.defaultOutputDirectory(for: request.inputURL.standardizedFileURL, layout: request.options.outputLayout)
            case .directory(let url): return url.standardizedFileURL
            case .temporary: return nil
            }
        }
        resolvedOutputs = outputs.map { $0?.resolvingSymlinksInPath() }
        try BatchSourceProtection.validate(outputs.compactMap { $0 } + roots, sources: sources)
        var reserved = [String]()
        var errors: [Int: ConversionError] = [:]
        for (index, output) in outputs.enumerated() {
            guard let output else { continue }
            let key = BatchSourceProtection.reservationKey(output)
            if reserved.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) {
                errors[index] = .outputAlreadyExists(output)
            } else { reserved.append(key) }
        }
        self.errors = errors
    }
    func prepareRoots(_ cancellation: ConversionCancellationToken) throws {
        try BatchSourceProtection.validate(outputs.compactMap { $0 } + roots, sources: sources)
        for root in roots {
            try cancellation.checkCancellation()
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) {
                guard directory.boolValue else { throw ConversionError.outputAlreadyExists(root) }
            } else {
                let parent = root.deletingLastPathComponent()
                guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else { throw ConversionError.outputParentDoesNotExist(root) }
                try BatchSourceProtection.validate([root], sources: sources)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            }
        }
    }
    func prepareParent(at index: Int) throws {
        for (path, snapshot) in sourceSnapshots {
            guard URL(fileURLWithPath: path).resolvingSymlinksInPath() == snapshot else { throw ConversionError.fileSystemFailure("a batch source changed after output planning") }
        }
        guard let output = outputs[index] else { return }
        guard output.resolvingSymlinksInPath() == resolvedOutputs[index] else { throw ConversionError.fileSystemFailure("the planned batch output location changed") }
        try BatchSourceProtection.validate([output, output.deletingLastPathComponent()], sources: sources)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}
