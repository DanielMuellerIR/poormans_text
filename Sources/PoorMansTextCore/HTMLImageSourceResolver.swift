import Foundation
import ImageIO

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
        fileManager: FileManager = .default,
        maximumImageBytes: Int = 512 * 1_024 * 1_024,
        maximumImageCount: Int = 1_024
    ) throws -> Resolution {
        let budget = ImageBudget(bytes: maximumImageBytes, count: maximumImageCount)
        let nsHTML = html as NSString
        var output = ""
        var cursor = 0
        var remote = 0
        var missing = 0
        var embedded = 0
        var localCount = 0
        var localNames = [String: String]()

        for match in try HTMLImageAttributes.imageTags(in: html) {
            try ConversionExecution.check()
            output += nsHTML.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let tag = nsHTML.substring(with: match.range)
            let attributes = try HTMLImageAttributes.read(in: tag)
            // Zeichenreferenzen aus dem Attribut bleiben HTML-Zeichenreferenzen;
            // nur echte Tag-Zeichen maskieren, sonst wird `&amp;` doppelt kodiert.
            let alt = (attributes["alt"]?.value ?? "")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            guard let sourceMatch = attributes["src"] else {
                // Ein `<img>` ohne `src` zeigt nichts; sein Alt-Text bleibt.
                output += alt
                missing += 1
                continue
            }
            let trimmed = try HTMLImageAttributes.decodedValue(sourceMatch.value)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.lowercased().hasPrefix("data:") {
                if let localPath = try extractEmbeddedImage(trimmed, index: embedded + 1, workDirectory: workDirectory, budget: budget) {
                    embedded += 1
                    output += replacingSource(in: tag, sourceRange: sourceMatch.range, with: localPath)
                } else {
                    output += alt
                    missing += 1
                }
                continue
            }

            // Nebenressourcen des Webarchivs zuerst, noch vor jeder Schema-Regel:
            // Ihre Bytes stammen aus dem Archiv selbst, nicht vom Netz oder von
            // der Platte. Ein lokal gesichertes Archiv trägt `file:`-Adressen;
            // die dürfen hier nachgeschlagen, aber nie als Pfad geöffnet werden.
            if let (key, subresource) = archivedSubresource(for: trimmed, baseURL: baseURL, in: subresources) {
                // Dieselbe Nebenressource einmal schreiben, nicht je Verweis:
                // Ein 200-mal verwendetes Spacer-GIF ergab 200 identische
                // Dateien (Roadmap-Punkt, 2026-09-10). Die Tabelle teilt sich
                // den Schlüsselraum mit lokalen Dateien; Adressen und Pfade
                // kollidieren nicht.
                let localPath: String
                if let known = localNames[key] {
                    localPath = known
                } else {
                    localCount += 1
                    guard let written = try writeLocalCopy(
                        subresource.data,
                        index: localCount,
                        workDirectory: workDirectory, budget: budget
                    ) else {
                        output += alt
                        missing += 1
                        continue
                    }
                    localPath = written
                    localNames[key] = written
                }
                output += replacingSource(in: tag, sourceRange: sourceMatch.range, with: localPath)
                continue
            }

            // Entfernte Adresse mit erlaubtem Schema: bleibt als Link erhalten.
            if let absolute = absoluteURL(trimmed, relativeTo: baseURL) {
                remote += 1
                output += "<a href=\"\(escaped(absolute.absoluteString))\">\(alt.isEmpty ? escaped(absolute.absoluteString) : alt)</a>"
                continue
            }

            if trimmed.lowercased().hasPrefix("file:") || URL(string: trimmed)?.scheme != nil {
                // `file:`-URLs und unbekannte Schemata sind kein lokaler Pfad
                // unterhalb der Quelle; sie fallen weg.
                output += alt
                missing += 1
                continue
            }

            // Auch extrahierte Paketmedien sind fremde Daten; ein sicherer Pfad
            // allein macht eine HTML- oder SVG-Datei noch nicht zu einem Bild.
            if let inWork = fileInside(workDirectory, relativePath: trimmed, fileManager: fileManager) {
                let localPath: String
                if let known = localNames[inWork.path] {
                    localPath = known
                } else {
                    localCount += 1
                    guard let copied = try copyLocalImage(inWork, index: localCount, workDirectory: workDirectory, fileManager: fileManager, budget: budget) else {
                        output += alt
                        missing += 1
                        continue
                    }
                    localPath = copied
                    localNames[inWork.path] = copied
                }
                output += replacingSource(in: tag, sourceRange: sourceMatch.range, with: localPath)
                continue
            }

            if let baseDirectory,
               let local = fileInside(baseDirectory, relativePath: trimmed, fileManager: fileManager) {
                let localPath: String
                if let known = localNames[local.path] {
                    localPath = known
                } else {
                    localCount += 1
                    guard let copied = try copyLocalImage(
                        local, index: localCount, workDirectory: workDirectory, fileManager: fileManager, budget: budget
                    ) else {
                        output += alt
                        missing += 1
                        continue
                    }
                    localPath = copied
                    localNames[local.path] = copied
                }
                output += replacingSource(in: tag, sourceRange: sourceMatch.range, with: localPath)
                continue
            }

            output += alt
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

    private final class ImageBudget {
        private var bytes: Int
        private var count: Int
        init(bytes: Int, count: Int) { self.bytes = max(0, bytes); self.count = max(0, count) }
        func reserve(_ size: Int) throws {
            guard size <= bytes, count > 0 else { throw ImportFailure("referenced images exceed the document asset budget") }
            bytes -= size
            count -= 1
        }
    }

    // MARK: - Hilfsfunktionen

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
        if reference.lowercased().hasPrefix("cid:"),
           let identifier = String(reference.dropFirst(4)).removingPercentEncoding {
            keys.append("cid:" + identifier)
        }
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
        // `?` und `#` trennen im URL-Text die Query beziehungsweise das
        // Fragment ab — im DATEINAMEN sind beide erlaubt. Deshalb erst der
        // vollständige Name, und nur wenn es den nicht gibt, der abgetrennte:
        // `Skizze #1.png` wurde vorher auf `Skizze ` gekürzt und galt als
        // fehlend, egal ob der Verweis kodiert war oder nicht
        // (Review-Fund 2026-09-10).
        let full = relativePath.removingPercentEncoding ?? relativePath
        if let found = candidate(in: directory, path: full, fileManager: fileManager) {
            return found
        }
        guard let separator = relativePath.firstIndex(where: { $0 == "?" || $0 == "#" }) else {
            return nil
        }
        let trimmed = String(relativePath[..<separator])
        return candidate(in: directory, path: trimmed.removingPercentEncoding ?? trimmed, fileManager: fileManager)
    }

    private static func candidate(in directory: URL, path: String, fileManager: FileManager) -> URL? {
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
    ///
    /// Ein Mangel der QUELLE — zu groß, keine reguläre Datei, nicht lesbar —
    /// macht nur diesen Verweis zum fehlenden Bild (`nil`), wie jeden anderen
    /// unbrauchbaren Verweis auch. Vorher brach ein 300-MiB-Bild neben der
    /// Quelle die gesamte Umwandlung als Dateisystemfehler ab (Roadmap-Punkt,
    /// 2026-09-10). Nur ein Fehler beim Schreiben der Kopie bleibt ein
    /// Dateisystemfehler.
    private static func copyLocalImage(_ source: URL, index: Int, workDirectory: URL, fileManager: FileManager, budget: ImageBudget) throws -> String? {
        let directory = workDirectory.appendingPathComponent("external", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        let staged = directory.appendingPathComponent(UUID().uuidString + ".candidate")
        do {
            try VerifiedFileStaging.withVerifiedSource(at: source, maximumBytes: maximumLocalImageBytes,
                describedAs: "a referenced image", followSourceSymlink: false) { verified, _ in
                let bytes = Int(verified.info.st_size)
                try budget.reserve(bytes)
                try VerifiedFileStaging.stage(from: verified, to: staged, maximumBytes: bytes, describedAs: "a referenced image")
            }
        } catch let error as VerifiedFileStaging.StagingError where error.kind == .source {
            try? fileManager.removeItem(at: staged)
            return nil
        } catch let error as VerifiedFileStaging.StagingError {
            throw ConversionError.fileSystemFailure(error.reason)
        }
        return try publishVerifiedImage(staged, as: String(format: "local%02d", index), fileManager: fileManager)
    }

    /// Prüft Bildtyp und dekodierbaren Inhalt der KOPIE und benennt sie nach
    /// diesem Typ. Die Endung stammte vorher aus dem fremden Verweis: Ein
    /// `<img src="seite.html">` landete dadurch als `images/image01.html` im
    /// Ergebnisordner und wurde im Markdown verlinkt — geöffnet lud diese Datei
    /// dann genau die entfernten Ressourcen nach, die der Kern nie lädt
    /// (Review-Fund 2026-09-10). Ist es kein Bild, verschwindet die Kopie und
    /// der Verweis zählt als fehlend.
    private static func publishVerifiedImage(
        _ staged: URL, as stem: String, fileManager: FileManager
    ) throws -> String? {
        guard let source = CGImageSourceCreateWithURL(staged as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let format = ImageFileFormat(typeIdentifier: typeIdentifier),
              // Ein erkannter Header genügt nicht: abgeschnittene Dateien
              // müssen den Fehlbildpfad mit Warnung und Alternativtext nutzen.
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              // Der Decoder muss Pixel liefern; ein lesbarer Header genügt nicht.
              image.dataProvider?.data != nil else {
            try? fileManager.removeItem(at: staged)
            return nil
        }
        let directory = staged.deletingLastPathComponent()
        var name = stem + "." + format.fileExtension
        // Paketmedien können bereits unter demselben generierten Namen liegen.
        // Die geprüfte Kopie darf diese fremde Datei weder ersetzen noch blockieren.
        if fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = stem + "-" + UUID().uuidString + "." + format.fileExtension
        }
        do {
            try fileManager.moveItem(at: staged, to: staged.deletingLastPathComponent().appendingPathComponent(name))
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        return "external/\(name)"
    }

    private static func writeLocalCopy(_ data: Data, index: Int, workDirectory: URL, budget: ImageBudget) throws -> String? {
        try budget.reserve(data.count)
        let directory = workDirectory.appendingPathComponent("external", isDirectory: true)
        let staged = directory.appendingPathComponent(UUID().uuidString + ".candidate")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: staged, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        // Auch hier entscheidet der Inhalt, nicht der Name: Eine Nebenressource
        // eines Webarchivs darf `WebResourceMIMEType: image/png` behaupten und
        // unter `…/evil.html` liegen.
        return try publishVerifiedImage(staged, as: String(format: "resource%02d", index), fileManager: .default)
    }

    /// `data:image/png;base64,…` in eine Datei; andere Daten-URIs fallen weg.
    private static func extractEmbeddedImage(_ reference: String, index: Int, workDirectory: URL, budget: ImageBudget) throws -> String? {
        guard let comma = reference.firstIndex(of: ",") else {
            return nil
        }
        let header = reference[reference.index(reference.startIndex, offsetBy: 5)..<comma].lowercased()
        let parts = header.split(separator: ";").map(String.init)
        guard let mime = parts.first, mime.hasPrefix("image/"), parts.contains("base64"),
              extensionForMIMEType(mime) != nil else {
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
        try budget.reserve(data.count)
        let directory = workDirectory.appendingPathComponent("external", isDirectory: true)
        let staged = directory.appendingPathComponent(UUID().uuidString + ".candidate")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: staged, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        // Auch eingebettete Quellen können ihren MIME-Typ falsch angeben oder
        // aktive SVG-Inhalte tragen. Dieselbe Inhaltsprüfung wie für lokale Bilder.
        return try publishVerifiedImage(staged, as: String(format: "embedded%02d", index), fileManager: .default)
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
