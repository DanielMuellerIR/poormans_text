import Foundation

struct HTMLRewriteResult: Sendable {
    let html: String
    let assetNames: [String]
    let sourceNames: Set<String>
}

enum HTMLImageRewriter {
    private static let imageSourcePattern = #"(<img\b[^>]*\bsrc\s*=\s*[\"'])([^\"']+)([\"'])"#

    static func rewrite(
        html: String,
        resourceDirectory: URL,
        imageDirectory: URL,
        fileManager: FileManager,
        inputURL: URL? = nil,
        format: InputFormat? = nil
    ) throws -> HTMLRewriteResult {
        let expression = try NSRegularExpression(
            pattern: imageSourcePattern,
            options: [.caseInsensitive]
        )
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = expression.matches(in: html, range: fullRange)
        let rewrittenHTML = NSMutableString(string: html)
        var outputNameBySource = [String: String]()
        var copiedAssetNames = [String]()
        var sourceNames = Set<String>()

        if !matches.isEmpty {
            do {
                try fileManager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            } catch {
                throw ConversionError.fileSystemFailure(error.localizedDescription)
            }
        }

        // Die von RTFD/textutil erzeugten Ressourcennamen können technische
        // Kollisionspräfixe wie `1__#$!@%!#__` enthalten. Für die Ausgabe sind
        // sie weder verständlich noch in allen Markdown-Renderern robust.
        // Deshalb werden unterschiedliche Bilder in Dokumentreihenfolge stabil
        // als image01, image02 usw. benannt; die Dateiendung bleibt erhalten.
        for match in matches {
            let encodedReference = (html as NSString).substring(with: match.range(at: 2))
            let sourceURL = try safeResourceURL(
                from: encodedReference,
                resourceDirectory: resourceDirectory
            )
            let sourceName = sourceURL.lastPathComponent
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                if let inputURL, let format {
                    throw ConversionError.invalidInput(
                        inputURL,
                        format: format,
                        reason: "generated image resource is missing: \(sourceName)"
                    )
                }
                throw ConversionError.invalidRichText(
                    resourceDirectory,
                    reason: "generated image resource is missing: \(sourceName)"
                )
            }

            if outputNameBySource[sourceURL.path] == nil {
                let outputName = sequentialName(
                    number: copiedAssetNames.count + 1,
                    sourceName: sourceName
                )
                let outputURL = imageDirectory.appendingPathComponent(outputName)
                do {
                    try fileManager.copyItem(at: sourceURL, to: outputURL)
                } catch {
                    throw ConversionError.fileSystemFailure(error.localizedDescription)
                }
                outputNameBySource[sourceURL.path] = outputName
                copiedAssetNames.append(outputName)
            }

            sourceNames.insert(sourceName)
        }

        // Von hinten ersetzen, damit die NSRanges der vorherigen Treffer trotz
        // unterschiedlich langer neuer Namen gültig bleiben.
        for match in matches.reversed() {
            let encodedReference = (html as NSString).substring(with: match.range(at: 2))
            let sourceURL = try safeResourceURL(
                from: encodedReference,
                resourceDirectory: resourceDirectory
            )
            guard let outputName = outputNameBySource[sourceURL.path] else {
                throw ConversionError.fileSystemFailure(
                    "internal image-name mapping is missing"
                )
            }
            let replacement = "images/" + percentEncodePathComponent(outputName)
            rewrittenHTML.replaceCharacters(in: match.range(at: 2), with: replacement)
        }

        return HTMLRewriteResult(
            html: rewrittenHTML as String,
            assetNames: copiedAssetNames,
            sourceNames: sourceNames
        )
    }

    private static func safeResourceURL(
        from reference: String,
        resourceDirectory: URL
    ) throws -> URL {
        let decodedReference = reference.replacingOccurrences(of: "&amp;", with: "&")
        let candidate: URL

        if let url = URL(string: decodedReference), url.scheme != nil {
            guard url.isFileURL else {
                throw ConversionError.unsafeImageReference(reference)
            }
            // textutil verwendet gelegentlich absolute File-URLs, obwohl es die
            // Ressource direkt neben das HTML geschrieben hat.
            let directURL = url.standardizedFileURL
            if isInside(directURL, directory: resourceDirectory) {
                candidate = directURL
            } else {
                candidate = resourceDirectory.appendingPathComponent(url.lastPathComponent)
            }
        } else {
            var path = decodedReference.removingPercentEncoding ?? decodedReference
            while path.hasPrefix("./") {
                path.removeFirst(2)
            }
            let components = NSString(string: path).pathComponents
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("\\"),
                  !components.contains("."),
                  !components.contains("..") else {
                throw ConversionError.unsafeImageReference(reference)
            }
            candidate = resourceDirectory.appendingPathComponent(path)
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard !resolvedCandidate.lastPathComponent.isEmpty,
              isInside(resolvedCandidate, directory: resourceDirectory) else {
            throw ConversionError.unsafeImageReference(reference)
        }
        return resolvedCandidate
    }

    private static func isInside(_ url: URL, directory: URL) -> Bool {
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(directoryPath)
    }

    private static func sequentialName(number: Int, sourceName: String) -> String {
        let fileExtension = URL(fileURLWithPath: sourceName).pathExtension.lowercased()
        let stem = String(format: "image%02d", number)
        return fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
    }

    private static func percentEncodePathComponent(_ component: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}
