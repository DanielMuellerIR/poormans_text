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
        var usedOutputNames = Set<String>()
        var copiedAssetNames = [String]()
        var sourceNames = Set<String>()

        if !matches.isEmpty {
            do {
                try fileManager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            } catch {
                throw ConversionError.fileSystemFailure(error.localizedDescription)
            }
        }

        for match in matches.reversed() {
            let encodedReference = rewrittenHTML.substring(with: match.range(at: 2))
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

            let outputName: String
            if let existingName = outputNameBySource[sourceURL.path] {
                outputName = existingName
            } else {
                outputName = uniqueName(for: sourceName, usedNames: &usedOutputNames)
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

    private static func uniqueName(for requestedName: String, usedNames: inout Set<String>) -> String {
        if usedNames.insert(requestedName).inserted {
            return requestedName
        }

        let requestedURL = URL(fileURLWithPath: requestedName)
        let fileExtension = requestedURL.pathExtension
        let stem = requestedURL.deletingPathExtension().lastPathComponent
        var number = 2

        while true {
            let candidate = fileExtension.isEmpty
                ? "\(stem)-\(number)"
                : "\(stem)-\(number).\(fileExtension)"
            if usedNames.insert(candidate).inserted {
                return candidate
            }
            number += 1
        }
    }

    private static func percentEncodePathComponent(_ component: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}
