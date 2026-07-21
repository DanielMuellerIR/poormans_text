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
        fileManager: FileManager
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
            let sourceName = try safeResourceName(from: encodedReference)
            let sourceURL = resourceDirectory.appendingPathComponent(sourceName)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
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

    private static func safeResourceName(from reference: String) throws -> String {
        let decodedReference = reference.replacingOccurrences(of: "&amp;", with: "&")
        let resourceName: String

        if let url = URL(string: decodedReference), url.scheme != nil {
            guard url.isFileURL else {
                throw ConversionError.unsafeImageReference(reference)
            }
            resourceName = url.lastPathComponent
        } else {
            resourceName = NSString(
                string: decodedReference.removingPercentEncoding ?? decodedReference
            ).lastPathComponent
        }

        guard !resourceName.isEmpty,
              resourceName != ".",
              resourceName != "..",
              !resourceName.contains("/") else {
            throw ConversionError.unsafeImageReference(reference)
        }
        return resourceName
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
