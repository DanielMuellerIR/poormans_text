import Foundation

enum CollectionPostprocessor {
    static func prepare(_ documents: [StagedConversionDocument], in root: URL, primary: String,
                        assets: [String], frontmatter: Bool) throws -> [ConversionWarning] {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard documents.count <= CollectionLimits.maximumDocuments, !primary.contains("/"),
              primary.hasSuffix(".md") else { throw ImportFailure("the collection overview or document count is invalid") }
        var paths = Set<String>()
        var markdownBytes = 0
        var assetBytes = 0
        var metadataBytes = 0
        var warnings: [ConversionWarning] = []
        func add(_ path: String) throws {
            guard paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ImportFailure("the collection reports duplicate output paths")
            }
            _ = try CollectionOutputPaths.file(path, in: root)
        }
        try add(primary)
        let overview = try VerifiedFileStaging.contents(of: root.appendingPathComponent(primary), maximumBytes: CollectionLimits.maximumOverviewBytes, describedAs: "the collection overview")
        guard String(data: overview, encoding: .utf8) != nil else { throw ImportFailure("the collection overview is not UTF-8") }
        markdownBytes = overview.count
        guard documents.flatMap(\.assetRelativePaths) == assets, assets.count <= CollectionLimits.maximumAssets else {
            throw ImportFailure("the collection asset ownership is inconsistent")
        }
        for (index, document) in documents.enumerated() {
            try ConversionExecution.check()
            let metadataSize = try JSONEncoder().encode(document.metadata).count
            let locationSize = try JSONEncoder().encode(document.location).count
            let prefix = String(format: "assets/documents/%06d/", index + 1)
            guard document.sourceIndex == index + 1, document.title.utf8.count <= CollectionLimits.maximumTitleBytes,
                  document.markdownRelativePath.hasPrefix(prefix), document.assetRelativePaths.allSatisfy({ $0.hasPrefix(prefix) }),
                  metadataSize <= CollectionLimits.maximumDocumentMetadataBytes, locationSize <= CollectionLimits.maximumLocationBytes,
                  metadataSize + locationSize <= CollectionLimits.maximumMetadataBytes - metadataBytes else {
                throw ImportFailure("the collection document metadata is invalid or exceeds its limits")
            }
            metadataBytes += metadataSize + locationSize
            try add(document.markdownRelativePath)
            let url = root.appendingPathComponent(document.markdownRelativePath)
            if frontmatter {
                if let header = document.metadata.frontmatter { try ConversionPostprocessor.prepend(header, to: url) }
                else { warnings.append(document.location.map { ConversionWarning.metadataUnavailable.at($0) } ?? .metadataUnavailable) }
            }
            let data = try VerifiedFileStaging.contents(of: url, maximumBytes: CollectionLimits.maximumDocumentBytes, describedAs: "a collection document")
            guard String(data: data, encoding: .utf8) != nil, data.count <= CollectionLimits.maximumMarkdownBytes - markdownBytes else {
                throw ImportFailure("the collection Markdown is invalid or exceeds its size limit")
            }
            markdownBytes += data.count
        }
        for path in assets {
            try ConversionExecution.check()
            try add(path)
            let count = try root.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard count >= 0, count <= CollectionLimits.maximumAssetBytes - assetBytes else { throw ImportFailure("the collection assets exceed their size limit") }
            assetBytes += count
        }
        var enumerationFailure: Error?
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey], errorHandler: { _, error in
            enumerationFailure = error
            return false
        }) else {
            throw ImportFailure("the collection output cannot be inspected")
        }
        var found = Set<String>()
        var entryCount = 0
        for case let url as URL in entries {
            try ConversionExecution.check()
            entryCount += 1
            guard entryCount <= CollectionLimits.maximumDirectoryEntries else { throw ImportFailure("the collection exceeds its directory entry limit") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw ImportFailure("the collection contains an output symlink") }
            if values.isRegularFile == true {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                guard canonical.path.hasPrefix(root.path + "/") else { throw ImportFailure("the collection enumerator left its output directory") }
                let path = String(canonical.path.dropFirst(root.path.count + 1)).precomposedStringWithCanonicalMapping.lowercased()
                guard paths.contains(path), found.insert(path).inserted else { throw ImportFailure("the collection contains an unreported output file: \(path)") }
            } else if values.isDirectory != true {
                throw ImportFailure("the collection contains a non-regular output file")
            }
        }
        if enumerationFailure != nil { throw ImportFailure("the complete collection output could not be inspected") }
        guard found == paths else { throw ImportFailure("the collection output is incomplete") }
        return warnings
    }

    static func applyTextbundle(in root: URL, primary: String, documents: [StagedConversionDocument]) throws -> String {
        if primary != "text.md" {
            for document in documents {
                try ConversionExecution.check()
                let directory = (document.markdownRelativePath as NSString).deletingLastPathComponent
                let depth = directory.split(separator: "/").count
                let prefix = String(repeating: "../", count: depth)
                let url = root.appendingPathComponent(document.markdownRelativePath)
                let text = try String(contentsOf: url, encoding: .utf8)
                let rewritten = try MarkdownLinkTargetRewriter.replacing(in: text, mapping: [prefix + primary: prefix + "text.md"], checking: ConversionExecution.check)
                if rewritten != text { try Data(rewritten.utf8).write(to: url, options: .atomic) }
            }
            try FileManager.default.moveItem(at: root.appendingPathComponent(primary), to: root.appendingPathComponent("text.md"))
        }
        try ConversionPostprocessor.writeTextbundleInfo(in: root)
        return "text.md"
    }

    static func mappings(_ documents: [StagedConversionDocument], in root: URL, frontmatter: Bool) throws -> [ConversionSourceMapping] {
        try documents.compactMap { document in
            try ConversionExecution.check()
            guard let location = document.location else { return nil }
            let data = try VerifiedFileStaging.contents(of: root.appendingPathComponent(document.markdownRelativePath),
                maximumBytes: CollectionLimits.maximumDocumentBytes, describedAs: "a mapped collection document")
            let offset = frontmatter ? document.metadata.frontmatter?.utf8.count ?? 0 : 0
            let range = ConversionTextRange(file: document.markdownRelativePath, utf8Offset: offset, utf8Length: data.count - offset)
            guard range.text(in: data) != nil else { throw ImportFailure("a collection mapping exceeds its document") }
            return ConversionSourceMapping(source: location, output: range)
        }
    }
}
