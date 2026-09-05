import Foundation

/// Formatneutrale Orchestrierung für Erkennung, Adapterwahl und Veröffentlichung.
public struct DocumentConverter: Sendable {
    private let adapters: [any DocumentConversionAdapter]

    public init() {
        self.init(adapters: [
            RichTextAdapter(),
            WordProcessingPackageAdapter(),
            LegacyWordAdapter(),
            SpreadsheetAdapter(),
            OpenDocumentMasterAdapter(),
            ImageAdapter(),
            PDFAdapter(),
            DelimitedTextAdapter(),
            PandocTextAdapter(),
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

    /// Alle bekannten Formate in stabiler Reihenfolge (Adapterreihenfolge, darin
    /// wie deklariert). Reine Deklaration, ohne jede Dateisystem- oder
    /// Prozessarbeit.
    public var supportedFormatDescriptors: [SupportedFormat] {
        adapters.flatMap(\.supportedFormatDescriptors)
    }

    /// Derselbe Katalog, zusätzlich mit der Verfügbarkeit auf DIESEM Rechner.
    ///
    /// Gedacht für Hosts, die vor dem Anbieten wissen müssen, ob eine
    /// Umwandlung überhaupt gelingen kann. Die Prüfung fasst nur das Dateisystem
    /// an und startet keinen Prozess — ein Host darf sie deshalb bei jedem
    /// Öffnen aufrufen.
    public func formatCatalog(
        resolver: ExternalToolResolver = ExternalToolResolver()
    ) -> [FormatAvailability] {
        // Jedes Werkzeug höchstens einmal prüfen: `pandoc` steht bei fast jedem
        // Format und würde sonst pro Format erneut im Dateisystem gesucht.
        var checked = [ExternalTool: Bool]()
        return supportedFormatDescriptors.map { descriptor in
            let missing = descriptor.requiredTools.filter { tool in
                if let known = checked[tool] { return !known }
                let available = resolver.isAvailable(tool)
                checked[tool] = available
                return !available
            }
            return FormatAvailability(
                format: descriptor,
                isAvailable: missing.isEmpty,
                unavailableReason: missing.isEmpty
                    ? nil
                    : "missing required tool: "
                        + missing.map(\.rawValue).joined(separator: ", "),
                missingTools: missing
            )
        }
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
        progress: ConversionProgressHandler? = nil,
        cancellation: ConversionCancellationToken? = nil,
        processTimeout: TimeInterval? = nil
    ) throws -> ConversionResult {
        let inherited = ConversionExecution.current
        let context = ConversionExecution.Context(
            cancellation: cancellation.map { ConversionCancellationToken(parent: $0) }
                ?? inherited?.cancellation ?? ConversionCancellationToken(),
            progress: progress ?? inherited?.progress,
            processTimeout: processTimeout ?? inherited?.processTimeout)
        return try ConversionExecution.$current.withValue(context) {
            do { return try convertInContext(request) }
            catch {
                // Parser und Systemadapter dürfen ihre Fehler übersetzen. Ein
                // angeforderter Abbruch bleibt an der API-Grenze trotzdem Abbruch.
                try context.cancellation.checkCancellation()
                throw error
            }
        }
    }

    private func convertInContext(_ request: ConversionRequest) throws -> ConversionResult {
        try ConversionExecution.report(ConversionProgress(phase: .detectingInput))
        let inputURL = request.inputURL.standardizedFileURL
        // Die echte Quelle wird GENAU EINMAL aufgelöst. Vorher löste jede Stufe
        // für sich auf: die Ausgabeprüfung vor dem Umwandeln, der Adapter beim
        // Lesen und die Ausgabeprüfung vor dem Veröffentlichen. Zeigte ein
        // Eingabe-Symlink bei beiden Prüfungen auf Paket A, während der Adapter
        // dazwischen Paket B erfasste, kam ein Ziel INNERHALB von B durch beide
        // Prüfungen — und die Umwandlung schrieb in das Quelldokument, das sie
        // gerade las (Review-Fund 2026-08-20).
        //
        // Die Erkennung läuft bewusst auf `inputURL`, weil Endungs-Adapter
        // (CSV, Pandoc-Textformate) den Namen des Links brauchen. Damit
        // Formatentscheidung und konvertierte Quelle dasselbe Objekt sind, wird
        // vor und nach der Erkennung aufgelöst; weichen beide Ergebnisse ab,
        // wurde der Link währenddessen umgehängt (Review-Fund 2026-09-03).
        let resolvedBeforeDetection = inputURL.resolvingSymlinksInPath()
        let detected = try detectInput(at: inputURL)
        let format = detected.inspection.format
        let resolvedInputURL = inputURL.resolvingSymlinksInPath()
        guard resolvedInputURL == resolvedBeforeDetection else {
            throw ConversionError.invalidInput(
                inputURL,
                format: format,
                reason: "the input changed while it was being inspected"
            )
        }

        try ConversionExecution.report(ConversionProgress(phase: .preparingOutput, format: format))
        let destination = try resolveDestination(for: request, inputURL: inputURL)
        let fileManager = FileManager.default
        try validateOutput(
            destination.url,
            resolvedInputURL: resolvedInputURL,
            fileManager: fileManager
        )

        let outputParent = destination.url.deletingLastPathComponent()
        let temporaryRoot = outputParent.appendingPathComponent(
            ".poormans-text-\(UUID().uuidString).tmp",
            isDirectory: true
        )
        let workDirectory = temporaryRoot.appendingPathComponent("work", isDirectory: true)
        let stagedOutput = temporaryRoot.appendingPathComponent("result", isDirectory: true)

        defer { try? fileManager.removeItem(at: temporaryRoot) }
        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagedOutput, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        try ConversionExecution.report(ConversionProgress(phase: .converting, format: format))
        let stagedResult = try detected.adapter.convert(
            AdapterConversionContext(
                inputURL: inputURL,
                resolvedInputURL: resolvedInputURL,
                format: format,
                workDirectory: workDirectory,
                stagedOutputDirectory: stagedOutput,
                options: request.options
            )
        )

        try ConversionExecution.check()
        var markdownRelativePath = try validateRelativePath(stagedResult.markdownRelativePath)
        var assetRelativePaths = try stagedResult.assetRelativePaths.map(validateRelativePath)
        var warnings = stagedResult.warnings
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

        // Nachbearbeitung noch im Staging-Bereich: Erst wenn Frontmatter und
        // Ablageform fertig sind, wird veröffentlicht — halbfertige Ergebnisse
        // erreichen das Ziel nie.
        if request.options.frontmatter {
            if let frontmatter = stagedResult.metadata.frontmatter {
                try ConversionPostprocessor.prepend(frontmatter, to: stagedMarkdown)
            } else {
                warnings.append(.metadataUnavailable)
            }
        }
        if request.options.outputLayout == .textbundle {
            (markdownRelativePath, assetRelativePaths) = try ConversionPostprocessor.applyTextbundleLayout(
                in: stagedOutput,
                markdownRelativePath: markdownRelativePath,
                assetRelativePaths: assetRelativePaths,
                fileManager: fileManager
            )
        }

        try ConversionExecution.report(ConversionProgress(phase: .publishing, format: format))
        try publish(
            stagedOutput,
            to: destination.url,
            resolvedInputURL: resolvedInputURL,
            fileManager: fileManager
        )

        let result = ConversionResult(
            inputURL: inputURL,
            format: format,
            outputDirectory: destination.url,
            markdownFile: destination.url.appendingPathComponent(markdownRelativePath),
            assets: assetRelativePaths.map { destination.url.appendingPathComponent($0) },
            outputLifetime: destination.lifetime,
            diagnostics: warnings,
            metadata: stagedResult.metadata
        )
        ConversionExecution.current?.progress?(ConversionProgress(phase: .finished, format: format))
        return result
    }

    public static func defaultOutputDirectory(
        for inputURL: URL,
        layout: OutputLayout = .markdownFolder
    ) -> URL {
        let inputURL = inputURL.standardizedFileURL
        return inputURL
            .deletingLastPathComponent()
            .appendingPathComponent(outputDirectoryName(for: inputURL, layout: layout), isDirectory: true)
    }

    /// Nur der Ordnername (`Eingabe-markdown` oder `Eingabe.textbundle`), damit
    /// ein Mehrfachlauf denselben Namen unter einem gemeinsamen Elternordner
    /// verwenden kann.
    public static func outputDirectoryName(
        for inputURL: URL,
        layout: OutputLayout = .markdownFolder
    ) -> String {
        let stem = inputURL.standardizedFileURL.deletingPathExtension().lastPathComponent
        switch layout {
        case .markdownFolder:
            return stem + InputEnumerator.outputDirectorySuffix
        case .textbundle:
            return stem + "." + InputEnumerator.textbundleExtension
        }
    }

    private func detectInput(at inputURL: URL) throws -> DetectedInput {
        // Ein einziger `stat` beantwortet beide Fragen: ob die Eingabe
        // überhaupt erreichbar ist und was für ein Objekt dort liegt. Als
        // Eingabe kommen nur reguläre Dateien und Ordnerpakete wie RTFD in
        // Frage. Der Rest — FIFO, Socket, Gerätedatei — wird hier abgewiesen,
        // BEVOR ein Adapter ihn öffnet: Ein `open` auf eine FIFO ohne Schreiber
        // kehrt nie zurück, und die Erkennung öffnet die Eingabe als Erstes.
        // Ein solcher Pfad ließ die Umwandlung ohne Zeitgrenze stehen
        // (gefunden beim Prüfen des Staging-Fundes vom 2026-08-19).
        var info = stat()
        guard stat(inputURL.path, &info) == 0 else {
            throw ConversionError.inputDoesNotExist(inputURL)
        }
        let inputKind = info.st_mode & S_IFMT
        guard inputKind == S_IFREG || inputKind == S_IFDIR else {
            throw ConversionError.unsupportedInput(inputURL)
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
    ) throws -> ResolvedDestination {
        let layout = request.options.outputLayout
        switch request.destination {
        case .adjacentToInput:
            return ResolvedDestination(
                url: Self.defaultOutputDirectory(for: inputURL, layout: layout),
                lifetime: .persistent
            )
        case .directory(let url):
            // Ein Textbundle ist für den Finder nur mit seiner Endung ein Paket.
            // Ein stilles Anhängen würde ein anderes Ziel erzeugen als genannt.
            if layout == .textbundle,
               url.pathExtension.lowercased() != InputEnumerator.textbundleExtension {
                throw ConversionError.invalidOutputName(
                    url,
                    reason: "a Textbundle output must end in .textbundle"
                )
            }
            return ResolvedDestination(url: url.standardizedFileURL, lifetime: .persistent)
        case .temporary:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PoorMansTextImport-\(UUID().uuidString)"
                    + (layout == .textbundle ? "." + InputEnumerator.textbundleExtension : ""),
                isDirectory: true
            )
            return ResolvedDestination(url: url, lifetime: .temporary)
        }
    }

    /// - Parameter resolvedInputURL: die einmal aufgelöste echte Quelle. Sie
    ///   kommt von außen, damit beide Prüfungen und der Adapter über DASSELBE
    ///   Dokument reden.
    private func validateOutput(
        _ outputURL: URL,
        resolvedInputURL: URL,
        fileManager: FileManager
    ) throws {
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw ConversionError.outputAlreadyExists(outputURL)
        }

        var resolvedInputPath = resolvedInputURL.path + "/"
        var resolvedOutputPath = outputURL.resolvingSymlinksInPath().path + "/"
        // `hasPrefix` vergleicht Zeichen für Zeichen. Auf einem Dateisystem, das
        // Groß-/Kleinschreibung im Namen nicht unterscheidet (Standard bei APFS),
        // zeigt "…/INPUT.RTFD/Converted" auf dasselbe Verzeichnis wie
        // "…/input.rtfd/Converted" und läge damit im Quelldokument. Deshalb dort
        // beide Pfade vor dem Vergleich kleinschreiben. Lässt sich die
        // Volume-Eigenschaft nicht ermitteln, wird ebenfalls kleingeschrieben:
        // Das ist die sichere Richtung, weil dann höchstens ein ohnehin
        // verdächtiges Ziel abgelehnt wird.
        let volumeValues = try? resolvedInputURL.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        )
        if volumeValues?.volumeSupportsCaseSensitiveNames != true {
            resolvedInputPath = resolvedInputPath.lowercased()
            resolvedOutputPath = resolvedOutputPath.lowercased()
        }
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
        resolvedInputURL: URL,
        fileManager: FileManager
    ) throws {
        // Die zweite Prüfung schließt das Zeitfenster zwischen Vorbereitung und
        // Veröffentlichung, ohne ein inzwischen angelegtes Ziel zu überschreiben.
        // Sie bekommt dieselbe aufgelöste Quelle wie die erste Prüfung.
        try validateOutput(
            outputURL,
            resolvedInputURL: resolvedInputURL,
            fileManager: fileManager
        )
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
    /// Die vollständige Beschreibung jedes angebotenen Formats. Sie ist die
    /// EINZIGE Stelle, an der ein Adapter seine Formate deklariert — Endungen,
    /// Ablageform und nötige Werkzeuge inklusive. Dadurch bleibt der
    /// veröffentlichte Formatkatalog automatisch vollständig, wenn ein neuer
    /// Adapter dazukommt.
    var supportedFormatDescriptors: [SupportedFormat] { get }

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection
    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult
}

extension DocumentConversionAdapter {
    var supportedFormats: Set<InputFormat> {
        Set(supportedFormatDescriptors.map(\.format))
    }
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
    /// Der vom Nutzer gewählte Pfad. Er benennt die Ausgabe und steht in den
    /// Fehlermeldungen.
    let inputURL: URL
    /// Dieselbe Quelle, aber EINMAL zentral aufgelöst. Adapter, die einem
    /// Verweis folgen müssen, nehmen diesen Pfad, statt selbst aufzulösen —
    /// sonst können Ausgabeprüfung und gelesenes Dokument auseinanderlaufen.
    let resolvedInputURL: URL
    let format: InputFormat
    let workDirectory: URL
    let stagedOutputDirectory: URL
    let options: ConversionOptions

    init(
        inputURL: URL,
        resolvedInputURL: URL? = nil,
        format: InputFormat,
        workDirectory: URL,
        stagedOutputDirectory: URL,
        options: ConversionOptions
    ) {
        self.inputURL = inputURL
        self.resolvedInputURL = resolvedInputURL ?? inputURL.resolvingSymlinksInPath()
        self.format = format
        self.workDirectory = workDirectory
        self.stagedOutputDirectory = stagedOutputDirectory
        self.options = options
    }
}

struct StagedConversionResult: Sendable {
    let markdownRelativePath: String
    let assetRelativePaths: [String]
    let warnings: [ConversionWarning]
    let metadata: DocumentMetadata

    init(
        markdownRelativePath: String,
        assetRelativePaths: [String],
        warnings: [ConversionWarning],
        metadata: DocumentMetadata = DocumentMetadata()
    ) {
        self.markdownRelativePath = markdownRelativePath
        self.assetRelativePaths = assetRelativePaths
        self.warnings = warnings
        self.metadata = metadata
    }
}
