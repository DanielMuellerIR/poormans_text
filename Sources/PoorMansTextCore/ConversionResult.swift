import Foundation

/// Lebensdauer des veröffentlichten Konvertierungsergebnisses.
public enum ConversionOutputLifetime: Equatable, Sendable {
    case persistent
    case temporary
}

/// Ergebnis einer erfolgreichen Dokumentkonvertierung.
public struct ConversionResult: Sendable {
    public let inputURL: URL
    public let format: InputFormat
    public let outputDirectory: URL
    public let markdownFile: URL
    public let assets: [URL]
    public let outputLifetime: ConversionOutputLifetime
    public let diagnostics: [ConversionWarning]
    /// Angaben aus dem Quelldokument, soweit das Format sie kennt.
    public let metadata: DocumentMetadata
    public let sourceIdentity: ConversionSourceIdentity?
    public let sourceMappings: [ConversionSourceMapping]
    public let outputFiles: [ConversionOutputFile]
    public let reportFile: URL?
    public var diagnosticGroups: [ConversionDiagnosticGroup] { ConversionDiagnosticGroup.grouped(diagnostics) }

    /// Quellkompatible Textsicht für CLI, App und bisherige Library-Aufrufer.
    public var warnings: [String] {
        diagnostics.map { warning in
            guard let label = warning.location?.label, !label.isEmpty else { return warning.message }
            return label + ": " + warning.message
        }
    }

    public init(
        inputURL: URL,
        format: InputFormat,
        outputDirectory: URL,
        markdownFile: URL,
        assets: [URL],
        outputLifetime: ConversionOutputLifetime,
        diagnostics: [ConversionWarning],
        metadata: DocumentMetadata = DocumentMetadata(),
        sourceIdentity: ConversionSourceIdentity? = nil,
        sourceMappings: [ConversionSourceMapping] = [],
        outputFiles: [ConversionOutputFile] = [],
        reportFile: URL? = nil
    ) {
        self.inputURL = inputURL
        self.format = format
        self.outputDirectory = outputDirectory
        self.markdownFile = markdownFile
        self.assets = assets
        self.outputLifetime = outputLifetime
        self.diagnostics = diagnostics
        self.metadata = metadata
        self.sourceIdentity = sourceIdentity
        self.sourceMappings = sourceMappings
        self.outputFiles = outputFiles
        self.reportFile = reportFile
    }

}
