import Foundation

/// Ergebnis einer erfolgreichen RTFD-Konvertierung.
public struct ConversionResult: Sendable {
    public let inputURL: URL
    public let outputDirectory: URL
    public let markdownFile: URL
    public let assets: [URL]
    public let warnings: [String]

    public init(
        inputURL: URL,
        outputDirectory: URL,
        markdownFile: URL,
        assets: [URL],
        warnings: [String]
    ) {
        self.inputURL = inputURL
        self.outputDirectory = outputDirectory
        self.markdownFile = markdownFile
        self.assets = assets
        self.warnings = warnings
    }
}
