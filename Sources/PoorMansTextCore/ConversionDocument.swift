import Foundation

/// Ein Dokument innerhalb eines Ergebnisses; die primäre Übersicht bleibt separat.
public struct ConversionDocument: Sendable {
    public let sourceIndex: Int
    public let title: String
    public let markdownFile: URL
    public let assets: [URL]
    public let metadata: DocumentMetadata

    public init(sourceIndex: Int, title: String, markdownFile: URL, assets: [URL], metadata: DocumentMetadata = .init()) {
        self.sourceIndex = sourceIndex
        self.title = title
        self.markdownFile = markdownFile
        self.assets = assets
        self.metadata = metadata
    }
}

struct StagedConversionDocument: Sendable {
    let sourceIndex: Int
    let title: String
    let markdownRelativePath: String
    let assetRelativePaths: [String]
    let metadata: DocumentMetadata
    let location: ConversionLocation?
}

enum CollectionLimits {
    static let maximumDocuments = 10_000
    static let maximumDocumentBytes = 16 * 1_048_576
    static let maximumOverviewBytes = 64 * 1_048_576
    static let maximumMarkdownBytes = 256 * 1_048_576
    static let maximumAssetBytes = 512 * 1_048_576
    static let maximumAssets = 100_000
    static let maximumDocumentMetadataBytes = 65_536
    static let maximumMetadataBytes = 16 * 1_048_576
    static let maximumLocationBytes = 16_384
    static let maximumTitleBytes = 4096
    static let maximumDirectoryEntries = 250_000
    static let maximumDiagnostics = 100_000
}

/// Gemeinsame Schlussstrecke für Archivadapter, ohne eigenes Veröffentlichungsziel.
struct CollectionOutputWriter {
    let context: AdapterConversionContext
    private(set) var documents: [StagedConversionDocument] = []
    private var warnings: [ConversionWarning] = []
    private var markdownBytes = 0
    private var assetBytes = 0
    private var assetCount = 0
    private var metadataBytes = 0

    init(context: AdapterConversionContext) { self.context = context }

    mutating func append(title: String, metadata: DocumentMetadata = .init(), location: ConversionLocation? = nil,
                         convert: (AdapterConversionContext) throws -> StagedConversionResult) throws {
        try ConversionExecution.check()
        guard documents.count < CollectionLimits.maximumDocuments, title.utf8.count <= CollectionLimits.maximumTitleBytes else {
            throw ImportFailure("the collection exceeds its document or title limit")
        }
        let index = documents.count + 1
        let prefix = String(format: "assets/documents/%06d", index)
        let directory = context.stagedOutputDirectory.appendingPathComponent(prefix, isDirectory: true)
        let work = context.workDirectory.appendingPathComponent(String(format: "document-%06d", index), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        let child = AdapterConversionContext(inputURL: context.inputURL, resolvedInputURL: context.resolvedInputURL,
            format: context.format, workDirectory: work, stagedOutputDirectory: directory, options: context.options)
        // Kindadapter kennen nur ihre eigene Markdown-Datei. Ihre lokalen Offsets
        // dürfen nicht als Positionen in der gemeinsamen Übersicht erscheinen.
        var execution = ConversionExecution.current
        execution?.recording = nil
        let result = try ConversionExecution.$current.withValue(execution) { try convert(child) }
        guard result.documents == nil else { throw ImportFailure("nested document collections are not supported") }
        let markdown = try CollectionOutputPaths.file(result.markdownRelativePath, in: directory)
        let data = try VerifiedFileStaging.contents(of: markdown, maximumBytes: CollectionLimits.maximumDocumentBytes, describedAs: "a collection document")
        guard String(data: data, encoding: .utf8) != nil, data.count <= CollectionLimits.maximumMarkdownBytes - markdownBytes else {
            throw ImportFailure("the collection Markdown is invalid or exceeds its size limit")
        }
        markdownBytes += data.count
        var unique = Set([result.markdownRelativePath.precomposedStringWithCanonicalMapping.lowercased()])
        var assets: [String] = []
        for path in result.assetRelativePaths {
            guard unique.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ImportFailure("a collection document reports the same output more than once")
            }
            let url = try CollectionOutputPaths.file(path, in: directory)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size >= 0, size <= CollectionLimits.maximumAssetBytes - assetBytes else { throw ImportFailure("the collection assets exceed their size limit") }
            assetBytes += size
            assets.append(prefix + "/" + path)
        }
        let effectiveMetadata = metadata.isEmpty ? result.metadata : metadata
        let size = try JSONEncoder().encode(effectiveMetadata).count
        let locationSize = try JSONEncoder().encode(location).count
        guard size <= CollectionLimits.maximumDocumentMetadataBytes, size <= CollectionLimits.maximumMetadataBytes - metadataBytes,
              locationSize <= CollectionLimits.maximumLocationBytes, locationSize <= CollectionLimits.maximumMetadataBytes - metadataBytes - size,
              result.warnings.count <= CollectionLimits.maximumDiagnostics - warnings.count,
              result.assetRelativePaths.count <= CollectionLimits.maximumAssets - assetCount else {
            throw ImportFailure("the collection exceeds its metadata, diagnostic or file limit")
        }
        metadataBytes += size + locationSize
        assetCount += result.assetRelativePaths.count
        warnings += result.warnings.map { warning in
            guard let location else { return warning }
            return warning.at((warning.location ?? .init()).merging(location))
        }
        let cleanTitle = title.components(separatedBy: .controlCharacters).joined(separator: " ")
        documents.append(.init(sourceIndex: index, title: cleanTitle.isEmpty ? String(index) : cleanTitle,
            markdownRelativePath: prefix + "/" + result.markdownRelativePath,
            assetRelativePaths: assets, metadata: effectiveMetadata, location: location))
    }

    func finish(metadata: DocumentMetadata = .init()) throws -> StagedConversionResult {
        try ConversionExecution.check()
        let title = (metadata.title ?? context.inputURL.lastPathComponent).components(separatedBy: .controlCharacters).joined(separator: " ")
        guard title.utf8.count <= CollectionLimits.maximumTitleBytes,
              try JSONEncoder().encode(metadata).count <= CollectionLimits.maximumDocumentMetadataBytes else { throw ImportFailure("the collection metadata exceeds its size limit") }
        var overview = "# " + MarkdownEscaping.inlineLiteral(title) + "\n\n"
        for document in documents {
            try ConversionExecution.check()
            overview += "\(document.sourceIndex). [" + MarkdownEscaping.inlineLiteral(document.title) + "](" + MarkdownLinkTargetRewriter.percentEncodedPath(document.markdownRelativePath) + ")\n"
        }
        if documents.isEmpty { overview += "No documents.\n" }
        try Data(overview.utf8).write(to: context.stagedOutputDirectory.appendingPathComponent("index.md"), options: .withoutOverwriting)
        return .init(markdownRelativePath: "index.md", assetRelativePaths: documents.flatMap(\.assetRelativePaths),
            warnings: warnings, metadata: metadata, documents: documents)
    }
}

enum CollectionOutputPaths {
    static func file(_ path: String, in root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\\"), !path.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ImportFailure("the collection contains an unsafe output path")
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).standardizedFileURL
        var info = stat()
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), url.resolvingSymlinksInPath().path == url.path,
              lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw ImportFailure("the collection reports a missing or unsafe output file")
        }
        return url
    }
}
