import Foundation

/// Bereitet die Bildverweise fremder HTML-Quellen für `HTMLImageRewriter` vor.
///
/// Der Rewriter kennt nur Dateien im Arbeitsordner. Eine HTML-Datei, ein
/// Webarchiv oder ein von Pandoc erzeugtes HTML aus Org/LaTeX verweist aber auf
/// drei andere Arten von Bildern:
///
/// - **Entfernte Bilder** (`http`, `https`, …) werden nie geladen. Das
///   `<img>` wird zu einem Link mit dem Alt-Text, damit die Adresse im
///   Markdown erhalten bleibt, ohne dass ein Viewer etwas nachlädt.
/// - **Eingebettete Bilder** (`data:image/…;base64,…`) werden in den
///   Arbeitsordner ausgepackt und damit zu normalen Assets.
/// - **Lokale Bilder** relativ zur Quelldatei werden nur übernommen, wenn sie
///   unterhalb des Quellordners liegen — kein absoluter Pfad, kein `..` nach
///   außen, kein symbolischer Link nach außen. Ein fehlendes Bild fällt weg
///   und hinterlässt seinen Alt-Text.
///
/// Webarchive liefern ihre Bilder als Nebenressourcen mit absoluter Adresse;
/// die Auflösung nimmt sie vor dem Netz-Fall.
enum HTMLImageSourceResolver {
    struct Resolution {
        let html: String
        let remoteImagesKeptAsLinks: Int
        let missingImagesDropped: Int
        let embeddedImagesExtracted: Int
    }

    /// Eine Nebenressource eines Webarchivs.
    struct Subresource {
        let data: Data
        let mimeType: String
    }

    private static let imageTagPattern = #"<img\b[^>]*>"#
    // Attributwerte in doppelten, einfachen oder gar keinen Anführungszeichen;
    // ein unquoted Wert endet am nächsten Leerraum oder Tag-Zeichen (HTML-Spec).
    private static let sourcePattern = #"\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
    private static let altPattern = #"\balt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
    /// Nur diese Schemata bleiben als Link im Markdown; alles andere (`javascript:`,
    /// `file:`, unbekannte Schemata) ist kein Bild und fällt weg.
    private static let linkableSchemes: Set<String> = ["http", "https", "ftp", "ftps"]
    static let maximumEmbeddedImageBytes = 16 * 1_024 * 1_024
    static let maximumLocalImageBytes = 256 * 1_024 * 1_024

    static func resolve(
        html: String,
        baseDirectory: URL?,
        baseURL: URL?,
        subresources: [String: Subresource],
        workDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Resolution {
        let tagExpression = try NSRegularExpression(pattern: imageTagPattern, options: [.caseInsensitive])
        let sourceExpression = try NSRegularExpression(pattern: sourcePattern, options: [.caseInsensitive])
        let altExpression = try NSRegularExpression(pattern: altPattern, options: [.caseInsensitive])
        let nsHTML = html as NSString
        var output = ""
        var cursor = 0
        var remote = 0
        var missing = 0
        var embedded = 0
        var localCount = 0
        var localNames = [String: String]()

        for match in tagExpression.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            try ConversionExecution.check()
            output += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let tag = nsHTML.substring(with: match.range)
            let alt = firstGroup(altExpression, in: tag) ?? ""
            guard let sourceMatch = sourceExpression.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
                  let reference = groupValue(sourceMatch, in: tag) else {
                // Ein `<img>` ohne `src` zeigt nichts; sein Alt-Text bleibt.
                output += escaped(alt)
                missing += 1
                continue
            }
            let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")

            if trimmed.lowercased().hasPrefix("data:") {
                if let localPath = try extractEmbeddedImage(trimmed, index: embedded + 1, workDirectory: workDirectory) {
                    embedded += 1
                    output += replacingSource(in: tag, sourceRange: sourceMatch.range, with: localPath)
                } else {
                    output += escaped(alt)
                    missing += 1
                }
                continue
            }

            // Nebenressourcen des Webarchivs zuerst, noch vor jeder Schema-Regel:
            // Ihre Bytes stammen aus dem Archiv selbst, nicht vom Netz oder von
            // der Platte. Ein lokal gesichertes Archiv trägt `file:`-Adressen;
            // die dürfen hier nachgeschlagen, aber nie als Pfad geöffnet werden.
            if let (key, subresource) = archivedSubresource(for: trimmed, baseURL: baseURL, in: subresources) {
                localCount += 1
                let localPath = try writeLocalCopy(
                    subresource.data,
                    preferredName: URL(string: key)?.lastPathComponent ?? key,
                    mimeType: subresource.mimeType,
                    index: localCount,
                    workDirectory: workDirectory
                )
                output += replacingSource(in: tag, sourceRange: sourceMatch.range, with: localPath)
                continue
            }

            // Entfernte Adresse mit erlaubtem Schema: bleibt als Link erhalten.
            if let absolute = absoluteURL(trimmed, relativeTo: baseURL) {
                remote += 1
                output += "<a href=\"\(escaped(absolute.absoluteString))\">\(escaped(alt.isEmpty ? absolute.absoluteString : alt))</a>"
                continue
            }

            if trimmed.lowercased().hasPrefix("file:") || URL(string: trimmed)?.scheme != nil {
                // `file:`-URLs und unbekannte Schemata sind kein lokaler Pfad
                // unterhalb der Quelle; sie fallen weg.
                output += escaped(alt)
                missing += 1
                continue
            }

            // Von Pandoc bereits in den Arbeitsordner extrahierte Medien bleiben.
            if let inWork = fileInside(workDirectory, relativePath: trimmed, fileManager: fileManager) {
                _ = inWork
                output += tag
                continue
            }

            if let baseDirectory,
               let local = fileInside(baseDirectory, relativePath: trimmed, fileManager: fileManager) {
                let localPath: String
                if let known = localNames[local.path] {
                    localPath = known
                } else {
                    localCount += 1
                    localPath = try copyLocalImage(local, index: localCount, workDirectory: workDirectory, fileManager: fileManager)
                    localNames[local.path] = localPath
                }
                output += replacingSource(in: tag, sourceRange: sourceMatch.range, with: localPath)
                continue
            }

            output += escaped(alt)
            missing += 1
        }
        output += nsHTML.substring(from: cursor)
        return Resolution(
            html: output,
            remoteImagesKeptAsLinks: remote,
            missingImagesDropped: missing,
            embeddedImagesExtracted: embedded
        )
    }

    // MARK: - Hilfsfunktionen

    private static func firstGroup(_ expression: NSRegularExpression, in text: String) -> String? {
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        return groupValue(match, in: text)
    }

    private static func groupValue(_ match: NSTextCheckingResult, in text: String) -> String? {
        for group in 1..<match.numberOfRanges {
            let range = match.range(at: group)
            if range.location != NSNotFound {
                return (text as NSString).substring(with: range)
            }
        }
        return nil
    }

    /// Ersetzt nur den Wert von `src` innerhalb des Tags.
    private static func replacingSource(in tag: String, sourceRange: NSRange, with localPath: String) -> String {
        let nsTag = tag as NSString
        let before = nsTag.substring(to: sourceRange.location)
        let after = nsTag.substring(from: sourceRange.location + sourceRange.length)
        return before + "src=\"\(escaped(localPath))\"" + after
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Die Adresse, wenn sie — direkt oder relativ zur Basis aufgelöst — eines
    /// der verlinkbaren Schemata trägt. Die Positivliste gilt NACH der
    /// Auflösung: Mit einer `http`-Basis ergab `javascript:alert(1)` vorher eine
    /// `javascript:`-URL, die nur gegen `file` geprüft und dann als Link
    /// ausgegeben wurde (Review-Fund 2026-09-03).
    private static func absoluteURL(_ reference: String, relativeTo base: URL?) -> URL? {
        let candidate: URL?
        if let url = URL(string: reference), url.scheme != nil {
            candidate = url
        } else if let base {
            candidate = URL(string: reference, relativeTo: base)?.absoluteURL
        } else {
            candidate = nil
        }
        guard let candidate, let scheme = candidate.scheme?.lowercased(),
              linkableSchemes.contains(scheme) else {
            return nil
        }
        return candidate
    }

    /// Sucht die Adresse unter den Nebenressourcen eines Webarchivs: wörtlich,
    /// als absolute URL und relativ zur Adresse der Hauptressource. Safari legt
    /// die Schlüssel als absolute Adressen ab, das HTML verweist aber oft relativ.
    private static func archivedSubresource(
        for reference: String,
        baseURL: URL?,
        in subresources: [String: Subresource]
    ) -> (key: String, subresource: Subresource)? {
        guard !subresources.isEmpty else {
            return nil
        }
        var keys = [reference]
        if let url = URL(string: reference), url.scheme != nil {
            keys.append(url.absoluteString)
        } else if let baseURL, let resolved = URL(string: reference, relativeTo: baseURL)?.absoluteURL {
            keys.append(resolved.absoluteString)
        }
        for key in keys {
            if let subresource = subresources[key] {
                return (key, subresource)
            }
        }
        return nil
    }

    /// Ein relativer Pfad unterhalb von `directory`, aufgelöst und geprüft; `nil`,
    /// wenn er fehlt, nach außen zeigt oder keine reguläre Datei ist. Die
    /// Prüfung folgt keinem Symlink mehr: `resolved` ist bereits aufgelöst, und
    /// eine FIFO, ein Gerät oder ein Socket an dieser Stelle ist kein Bild.
    private static func fileInside(_ directory: URL, relativePath: String, fileManager: FileManager) -> URL? {
        var path = relativePath.removingPercentEncoding ?? relativePath
        if let query = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<query])
        }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            return nil
        }
        let candidate = directory.appendingPathComponent(path).standardizedFileURL
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            return nil
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(directoryPath) else {
            return nil
        }
        var info = stat()
        guard lstat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return resolved
    }

    /// Kopiert das geprüfte Bild über einen geöffneten Deskriptor in den
    /// Arbeitsordner. `VerifiedFileStaging` prüft Dateityp und Größe an genau
    /// dem Objekt, das es liest, und folgt keinem Symlink: Ein Austausch der
    /// Datei zwischen `fileInside` und dem Kopieren kann so weder die
    /// 256-MiB-Grenze noch die Bindung an den Quellordner umgehen.
    private static func copyLocalImage(_ source: URL, index: Int, workDirectory: URL, fileManager: FileManager) throws -> String {
        let fileExtension = source.pathExtension.lowercased()
        let name = String(format: "local%02d", index) + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        let directory = workDirectory.appendingPathComponent("external", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        do {
            _ = try VerifiedFileStaging.stage(
                from: source,
                to: directory.appendingPathComponent(name),
                maximumBytes: maximumLocalImageBytes,
                describedAs: "a referenced image",
                followSourceSymlink: false
            )
        } catch let error as VerifiedFileStaging.StagingError {
            throw ConversionError.fileSystemFailure(error.reason)
        }
        return "external/\(name)"
    }

    private static func writeLocalCopy(_ data: Data, preferredName: String, mimeType: String, index: Int, workDirectory: URL) throws -> String {
        var fileExtension = URL(fileURLWithPath: preferredName).pathExtension.lowercased()
        if fileExtension.isEmpty {
            fileExtension = extensionForMIMEType(mimeType) ?? ""
        }
        let name = String(format: "resource%02d", index) + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        let directory = workDirectory.appendingPathComponent("external", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        return "external/\(name)"
    }

    /// `data:image/png;base64,…` in eine Datei; andere Daten-URIs fallen weg.
    private static func extractEmbeddedImage(_ reference: String, index: Int, workDirectory: URL) throws -> String? {
        guard let comma = reference.firstIndex(of: ",") else {
            return nil
        }
        let header = reference[reference.index(reference.startIndex, offsetBy: 5)..<comma].lowercased()
        let parts = header.split(separator: ";").map(String.init)
        guard let mime = parts.first, mime.hasPrefix("image/"), parts.contains("base64"),
              let fileExtension = extensionForMIMEType(mime) else {
            return nil
        }
        let payload = String(reference[reference.index(after: comma)...])
        // Base64-Daten sind ein Drittel größer als das Bild; vor dem Dekodieren
        // begrenzen, damit ein riesiger Text nicht erst entpackt wird.
        guard payload.utf8.count <= maximumEmbeddedImageBytes * 4 / 3 + 4,
              let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              !data.isEmpty, data.count <= maximumEmbeddedImageBytes else {
            return nil
        }
        let name = String(format: "embedded%02d.%@", index, fileExtension)
        let directory = workDirectory.appendingPathComponent("embedded", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        return "embedded/\(name)"
    }

    static func extensionForMIMEType(_ mimeType: String) -> String? {
        switch mimeType.lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/bmp", "image/x-ms-bmp": "bmp"
        case "image/tiff": "tiff"
        case "image/heic": "heic"
        case "image/svg+xml": "svg"
        default: nil
        }
    }
}
