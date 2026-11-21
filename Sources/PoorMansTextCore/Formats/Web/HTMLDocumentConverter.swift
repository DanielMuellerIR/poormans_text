import Foundation

struct HTMLDocumentConversion {
    let markdownRelativePath: String
    let assetRelativePaths: [String]
    let referencedResourceNames: Set<String>
}

/// Gemeinsame sichere Schlussstrecke für Adapter, die zunächst lokales HTML erzeugen.
enum HTMLDocumentConverter {
    static func convert(
        html: String,
        inputURL: URL,
        format: InputFormat,
        resourceDirectory: URL,
        stagedOutputDirectory: URL,
        pandocExecutable: URL,
        fileManager: FileManager = .default
    ) throws -> HTMLDocumentConversion {
        let imageDirectory = stagedOutputDirectory.appendingPathComponent(
            "images",
            isDirectory: true
        )
        let rewriteResult = try HTMLImageRewriter.rewrite(
            html: html,
            resourceDirectory: resourceDirectory,
            imageDirectory: imageDirectory,
            fileManager: fileManager,
            inputURL: inputURL,
            format: format
        )
        let normalizedHTML = stagedOutputDirectory.appendingPathComponent(".conversion.html")

        do {
            try Data(rewriteResult.html.utf8).write(to: normalizedHTML, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        // Sicherheitsnetz für die Fehlerpfade. Im Erfolgsfall wird die Datei
        // weiter unten ausdrücklich entfernt, und ein Fehler dabei wird gemeldet:
        // `DocumentConverter` verschiebt das ganze Staging-Verzeichnis ans Ziel,
        // eine übrig gebliebene Zwischendatei landete also im Ausgabeordner.
        defer {
            try? fileManager.removeItem(at: normalizedHTML)
        }

        let markdownName = inputURL.deletingPathExtension().lastPathComponent + ".md"
        let stagedMarkdown = stagedOutputDirectory.appendingPathComponent(markdownName)
        let pandocResult: ProcessResult
        do {
            pandocResult = try ProcessRunner.run(
                executable: pandocExecutable,
                arguments: [
                    // Gleiche Isolationsstufe wie im Paketadapter; alle Bildpfade
                    // sind zu diesem Zeitpunkt lokale, geprüfte Pfade.
                    "--sandbox",
                    "--from=html",
                    "--to=gfm-raw_html",
                    "--wrap=preserve",
                    "--output", stagedMarkdown.path,
                    normalizedHTML.path,
                ],
                currentDirectory: stagedOutputDirectory
            )
        } catch {
            throw ConversionError.pandocFailed(status: -1, message: error.localizedDescription)
        }

        guard pandocResult.status == 0 else {
            throw ConversionError.pandocFailed(
                status: pandocResult.status,
                message: pandocResult.standardError
            )
        }

        let markdown: String
        do {
            markdown = try String(contentsOf: stagedMarkdown, encoding: .utf8)
        } catch {
            // Pandoc hat mit 0 geendet: Fehlt sein Ergebnis trotzdem oder ist es
            // unlesbar, liegt das am Konverter oder am Dateisystem — nicht am
            // Quelldokument. `invalidInput` gaebe der CLI sonst Exit 65 statt 74
            // und schoebe einem gueltigen Dokument die Schuld zu.
            throw ConversionError.fileSystemFailure(
                "conversion produced no readable Markdown: \(error.localizedDescription)"
            )
        }
        do {
            let normalizedMarkdown = MarkdownNormalizer.normalize(markdown)
            try Data(normalizedMarkdown.utf8).write(to: stagedMarkdown, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        do {
            try fileManager.removeItem(at: normalizedHTML)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        return HTMLDocumentConversion(
            markdownRelativePath: markdownName,
            assetRelativePaths: rewriteResult.assetNames.sorted().map { "images/\($0)" },
            referencedResourceNames: rewriteResult.sourceNames
        )
    }
}
