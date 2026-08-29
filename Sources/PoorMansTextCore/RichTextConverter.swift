import Foundation

/// Quellkompatible Fassade für Aufrufer der bisherigen Rich-Text-API.
public struct RichTextConverter: Sendable {
    public init() {}

    public func convert(
        inputURL: URL,
        outputDirectory requestedOutputDirectory: URL? = nil,
        pandocExecutable requestedPandocExecutable: URL? = nil
    ) throws -> ConversionResult {
        let destination = requestedOutputDirectory.map(ConversionDestination.directory)
            ?? .adjacentToInput
        return try DocumentConverter().convert(
            ConversionRequest(
                inputURL: inputURL,
                destination: destination,
                options: ConversionOptions(pandocExecutable: requestedPandocExecutable)
            )
        )
    }

    public static func defaultOutputDirectory(for inputURL: URL) -> URL {
        DocumentConverter.defaultOutputDirectory(for: inputURL)
    }
}

enum RichTextLimits {
    /// Obergrenze für eine RTF-Quelldatei: 256 MiB.
    ///
    /// RTF liegt beim Umwandeln mehrfach im Speicher — als gelesene Quelle, als
    /// Bytefeld und als Ergebnis des Absatz-Rewriters —, dazu liest die
    /// Farberkennung dieselbe Datei noch einmal. Eine Textdatei dieser Größe ist
    /// weit jenseits dessen, was ein Textprogramm erzeugt; ohne Grenze konnte
    /// eine präparierte Datei den Prozess allein über den Speicher beenden
    /// (Review-Fund 2026-08-20).
    static let maximumSourceSize = 268_435_456
}

/// RTF und RTFD behalten getrennte Importwege, liefern aber dasselbe gestagte Ergebnis.
struct RichTextAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors: [SupportedFormat] = [
        SupportedFormat(
            format: .rtf,
            fileExtensions: ["rtf"],
            containerKind: .file,
            requiredTools: [.pandoc]
        ),
        // RTFD ist im Finder ein Ordner mit `TXT.rtf` und Bildern. Ein Host, der
        // Ordner sonst anders behandelt, erkennt das an `containerKind`.
        // RTFD braucht beide Werkzeuge: `textutil` erzeugt das HTML, Pandoc
        // wandelt es anschließend nach Markdown.
        SupportedFormat(
            format: .rtfd,
            fileExtensions: ["rtfd"],
            containerKind: .package,
            requiredTools: [.pandoc, .textutil]
        ),
    ]

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
            return .noMatch
        }

        if isDirectory.boolValue {
            let rtfURL = inputURL.appendingPathComponent("TXT.rtf")
            var rtfIsDirectory: ObjCBool = false
            let hasRTFFile = fileManager.fileExists(atPath: rtfURL.path, isDirectory: &rtfIsDirectory)
                && !rtfIsDirectory.boolValue
            if hasRTFFile, let probe = try rtfProbe(at: rtfURL), probe.hasHeader {
                // Dieselbe Grenze wie für die einzelne RTF-Datei, nur eine Ebene
                // tiefer: `textutil` und die Farberkennung laden auch die
                // `TXT.rtf` eines Pakets vollständig. Ohne die Prüfung stand der
                // Weg über ein Paket weiter offen (Review-Fund 2026-08-20 galt
                // nur für die freie Datei).
                guard probe.byteCount <= RichTextLimits.maximumSourceSize else {
                    return .invalid(
                        format: .rtfd,
                        priority: 100,
                        reason: "TXT.rtf exceeds the supported size limit"
                    )
                }
                return .match(
                    AdapterInputInspection(format: .rtfd, priority: 100, expectedWarnings: [])
                )
            }
            if inputURL.pathExtension.lowercased() == "rtfd" {
                let reason = hasRTFFile ? "TXT.rtf has no RTF header" : "TXT.rtf is missing"
                return .invalid(format: .rtfd, priority: 100, reason: reason)
            }
            return .noMatch
        }

        if let probe = try rtfProbe(at: inputURL), probe.hasHeader {
            // Schon die Farberkennung liest die ganze Datei in den Speicher.
            // Ohne diese Grenze konnte eine beliebig große Datei mit gültigem
            // RTF-Kopf den Prozess beenden (Review-Fund 2026-08-20).
            guard probe.byteCount <= RichTextLimits.maximumSourceSize else {
                return .invalid(
                    format: .rtf,
                    priority: 100,
                    reason: "the RTF file exceeds the supported size limit"
                )
            }
            let warnings: [ConversionWarning] = ColoredTextMarker.containsChromaticText(
                inRTF: inputURL
            ) ? [.richTextColorNotPreserved] : []
            return .match(
                AdapterInputInspection(format: .rtf, priority: 100, expectedWarnings: warnings)
            )
        }
        if inputURL.pathExtension.lowercased() == "rtf" {
            return .invalid(
                format: .rtf,
                priority: 100,
                reason: "the RTF header is missing"
            )
        }
        return .noMatch
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        let fileManager = FileManager.default
        let inputURL = context.inputURL
        let inputKind = context.format
        let workDirectory = context.workDirectory
        let stagedResult = context.stagedOutputDirectory
        let pandocExecutable = try PandocTool.resolve(
            context.options.pandocExecutable,
            fileManager: fileManager
        )
        // Der Verweis auf die Eingabe ist GENAU EINMAL aufgelöst — seit dem
        // Review vom 2026-08-20 zentral vor der Ausgabeprüfung, damit Prüfung
        // und Adapter über dasselbe Dokument reden. Alle Lesevorgänge hier
        // arbeiten auf diesem einen Pfad, für beide Wege:
        //
        // - RTFD ist ein Ordnerpaket, und `textutil` öffnet einen Symlink darauf
        //   gar nicht. Löste jede Stufe für sich auf und wurde der Verweis
        //   dazwischen umgebogen, stammten Inhalt und Anhänge eines Ergebnisses
        //   aus verschiedenen Paketen (Review-Fund 2026-08-19).
        // - Die einzelne RTF-Datei wird über denselben Pfad gestagt. Vorher
        //   stand hier der symbolische `inputURL`: Wurde er nach der Erkennung,
        //   aber vor dem Staging umgehängt, veröffentlichte der Adapter ein
        //   anderes Dokument als das geprüfte (Review-Fund 2026-08-25).
        //
        // `inputURL` bleibt daneben der vom Nutzer gewählte Pfad: Er benennt die
        // Ausgabedatei und steht in den Fehlermeldungen.
        let resolvedInputURL = context.resolvedInputURL

        // Eine einzelne RTF-Datei wird EINMAL begrenzt in den Arbeitsordner
        // gestagt. Danach lesen HTML-Erzeugung, Absatz-Rewriter und Farbwarnung
        // dieselbe unveränderliche Kopie. Vorher las jede Stufe die Quelle neu:
        // Wurde die Datei während des Pandoc-Laufs ausgetauscht, beschrieb die
        // Warnung ein anderes Dokument als das umgewandelte — und eine Grenze
        // für die Dateigröße gab es auf diesem Weg überhaupt nicht
        // (Review-Fund 2026-08-20).
        let sourceURL: URL
        if inputKind == .rtf {
            let stagedSource = workDirectory.appendingPathComponent("verified-source.rtf")
            do {
                try VerifiedFileStaging.stage(
                    from: resolvedInputURL,
                    to: stagedSource,
                    maximumBytes: RichTextLimits.maximumSourceSize,
                    describedAs: "the RTF source"
                )
            } catch let error as VerifiedFileStaging.StagingError where error.kind == .source {
                throw ConversionError.invalidRichText(inputURL, reason: error.reason)
            } catch let error as VerifiedFileStaging.StagingError {
                throw ConversionError.fileSystemFailure(error.reason)
            }
            sourceURL = stagedSource
        } else {
            sourceURL = resolvedInputURL
        }
        let htmlURL = workDirectory.appendingPathComponent("document.html")
        let emptyParagraphMarker = inputKind == .rtf
            ? "POORMANSTEXTEMPTY\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            : nil
        try createHTML(
            from: sourceURL,
            kind: inputKind,
            at: htmlURL,
            workDirectory: workDirectory,
            pandocExecutable: pandocExecutable,
            emptyParagraphMarker: emptyParagraphMarker
        )

        var html: String
        do {
            html = try String(contentsOf: htmlURL, encoding: .utf8)
        } catch {
            throw ConversionError.invalidRichText(
                inputURL,
                reason: "conversion produced no readable HTML"
            )
        }
        if let emptyParagraphMarker {
            // Pandocs RTF-Reader verwirft leere Absätze. Der Marker wird vor
            // dieser Stufe eingefügt und hier in einen sichtbaren Leerabsatz
            // zurückübersetzt.
            html = html.replacingOccurrences(of: emptyParagraphMarker, with: "<br>")
        }
        html = unwrappingListParagraphs(in: html)

        let converted = try HTMLDocumentConverter.convert(
            html: html,
            inputURL: inputURL,
            format: inputKind,
            resourceDirectory: workDirectory,
            stagedOutputDirectory: stagedResult,
            pandocExecutable: pandocExecutable,
            fileManager: fileManager
        )

        let warnings = warnings(
            inputURL: sourceURL,
            kind: inputKind,
            referencedResourceNames: converted.referencedResourceNames,
            fileManager: fileManager
        )

        return StagedConversionResult(
            markdownRelativePath: converted.markdownRelativePath,
            assetRelativePaths: converted.assetRelativePaths,
            warnings: warnings
        )
    }

    private func createHTML(
        from inputURL: URL,
        kind: InputFormat,
        at htmlURL: URL,
        workDirectory: URL,
        pandocExecutable: URL,
        emptyParagraphMarker: String?
    ) throws {
        if kind == .rtfd {
            let markedRTFD = workDirectory.appendingPathComponent("marked.rtfd", isDirectory: true)
            let textutilInput = try ColoredTextMarker.markedInputURL(
                from: inputURL,
                outputURL: markedRTFD
            )
            // Ohne Farbmarker reicht `markedInputURL` den Eingabepfad unverändert
            // durch. Der ist hier bereits aufgelöst — der Aufrufer hat das genau
            // einmal vor dem ersten Lesen erledigt —, deshalb bekommt `textutil`
            // denselben Pfad, den auch der Farbmarker gelesen hat.
            let textutilInputPath = textutilInput.path
            let result: ProcessResult
            do {
                result = try ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/textutil"),
                    arguments: ["-convert", "html", "-output", htmlURL.path, textutilInputPath],
                    currentDirectory: workDirectory
                )
            } catch {
                throw ConversionError.textutilFailed(status: -1, message: error.localizedDescription)
            }
            guard result.status == 0 else {
                throw ConversionError.textutilFailed(
                    status: result.status,
                    message: result.standardError
                )
            }

        } else if kind == .rtf {
            guard let emptyParagraphMarker else {
                throw ConversionError.fileSystemFailure("internal RTF marker is missing")
            }
            let preparedRTF = workDirectory.appendingPathComponent("document.rtf")
            do {
                let source = try Data(contentsOf: inputURL)
                let prepared = preservingEmptyRTFParagraphs(
                    in: source,
                    marker: emptyParagraphMarker
                )
                try prepared.write(to: preparedRTF, options: .atomic)
            } catch {
                throw ConversionError.fileSystemFailure(error.localizedDescription)
            }

            let result: ProcessResult
            do {
                result = try ProcessRunner.run(
                    executable: pandocExecutable,
                    arguments: [
                        // Gleiche Isolationsstufe wie im Paketadapter; alle Bildpfade
                        // sind zu diesem Zeitpunkt lokale, geprüfte Pfade.
                        "--sandbox",
                        "--from=rtf",
                        "--to=html5",
                        "--extract-media=.",
                        "--wrap=preserve",
                        "--output", htmlURL.path,
                        preparedRTF.path,
                    ],
                    currentDirectory: workDirectory
                )
            } catch {
                throw ConversionError.pandocFailed(status: -1, message: error.localizedDescription)
            }
            guard result.status == 0 else {
                throw ConversionError.pandocFailed(
                    status: result.status,
                    message: result.standardError
                )
            }
        } else {
            throw ConversionError.unsupportedInput(inputURL)
        }
    }

    /// Was der Blick in die ersten Bytes einer möglichen RTF-Datei ergeben hat.
    struct RTFProbe {
        let hasHeader: Bool
        let byteCount: Int
    }

    /// Öffnet die Datei GENAU EINMAL, prüft mit `fstat` am selben Deskriptor,
    /// dass wirklich eine reguläre Datei dahintersteht, und liest daraus die
    /// ersten 32 Byte. Ergebnis `nil` heißt: keine reguläre Datei.
    ///
    /// `O_NONBLOCK` ist der Schutz vor dem Aufhängen. In einem RTFD-Ordner darf
    /// `TXT.rtf` alles Mögliche sein, auch eine FIFO; ein `open` darauf ohne
    /// Schreiber kehrt sonst NIE zurück, und die Umwandlung steht ohne
    /// Zeitgrenze. Die Prüfung des äußeren Ordners sieht das nicht
    /// (Review-Fund 2026-08-20).
    func rtfProbe(at url: URL) throws -> RTFProbe? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw ConversionError.fileSystemFailure(
                "\(url.lastPathComponent) could not be opened: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw ConversionError.fileSystemFailure(
                "\(url.lastPathComponent) could not be inspected"
            )
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return nil
        }

        let headerLength = 32
        var bytes = [UInt8](repeating: 0, count: headerLength)
        var readTotal = 0
        while readTotal < headerLength {
            let readBytes = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(descriptor, base + readTotal, headerLength - readTotal)
            }
            if readBytes == 0 {
                break                      // die Datei ist kürzer als 32 Byte
            }
            guard readBytes > 0 else {
                if errno == EINTR { continue }
                throw ConversionError.fileSystemFailure(
                    "\(url.lastPathComponent) could not be read"
                )
            }
            readTotal += readBytes
        }

        let header = Array(bytes[0..<readTotal])
        let signature = [UInt8](#"{\rtf"#.utf8)
        guard header.starts(with: signature) else {
            return RTFProbe(hasHeader: false, byteCount: Int(info.st_size))
        }
        // `\rtf` ist ein Steuerwort mit verpflichtender Versionszahl.
        let versionStart = signature.count
        return RTFProbe(
            hasHeader: versionStart < header.count && header[versionStart].isASCIIDigit,
            byteCount: Int(info.st_size)
        )
    }

    /// Schützt direkt aufeinanderfolgende `\\par`-Steuerwörter vor Pandocs
    /// Zusammenfaltung. Escapte Backslashes werden dabei nicht als Steuerwort
    /// interpretiert; das Quelldokument selbst bleibt unverändert.
    func preservingEmptyRTFParagraphs(in data: Data, marker: String) -> Data {
        let bytes = [UInt8](data)
        let markerBytes = [UInt8](" \(marker)".utf8)
        var result = Data()
        result.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x5C, index + 1 < bytes.count else {
                result.append(bytes[index])
                index += 1
                continue
            }

            // Manche Apple-Programme beenden einen Absatz mit einem Backslash
            // direkt vor dem echten Zeilenumbruch. Pandoc liest das nur als
            // manuellen Umbruch; `\\par` stellt die Absatzgrenze wieder her.
            if bytes[index + 1] == 0x0A || bytes[index + 1] == 0x0D {
                result.append(contentsOf: [0x5C, 0x70, 0x61, 0x72])
                index += 1
                continue
            }

            // RTF-Control-Symbole wie `\\\\` maskieren genau das Folgezeichen.
            // So kann dessen Backslash nicht irrtümlich als `\\par` beginnen.
            guard isASCIIAlpha(bytes[index + 1]) else {
                result.append(bytes[index])
                result.append(bytes[index + 1])
                index += 2
                continue
            }

            guard let control = rtfControlWord(in: bytes, at: index) else {
                result.append(bytes[index])
                index += 1
                continue
            }
            result.append(contentsOf: bytes[index..<control.end])
            if control.word == "bin", let byteCount = control.parameter, byteCount > 0 {
                var binaryStart = control.end
                if binaryStart < bytes.count, bytes[binaryStart] == 0x20 {
                    result.append(bytes[binaryStart])
                    binaryStart += 1
                }
                let availableBytes = bytes.count - binaryStart
                let binaryEnd = byteCount > availableBytes
                    ? bytes.count
                    : binaryStart + byteCount
                result.append(contentsOf: bytes[binaryStart..<binaryEnd])
                index = binaryEnd
                continue
            }
            if control.word == "par",
               nextRTFControlWord(in: bytes, after: control.end)?.word == "par" {
                result.append(contentsOf: markerBytes)
            }
            index = control.end
        }
        return result
    }

    /// Pandocs RTF-Reader legt selbst einfache Listeneinträge als eigenen
    /// Absatz in `<li>` ab. Ohne diese enge Korrektur schreibt der nächste
    /// Pandoc-Lauf daraus eine lose Liste mit Leerzeilen. Einträge mit mehreren
    /// Absätzen oder verschachtelten Elementen bleiben bewusst unverändert.
    ///
    /// Im Absatz sind neben reinem Text ausdrücklich die üblichen
    /// Auszeichnungen erlaubt — ohne sie fiele schon ein fett gesetztes Wort im
    /// Listeneintrag aus der Korrektur heraus. Alles andere, insbesondere ein
    /// zweiter Absatz oder eine verschachtelte Liste, passt weiterhin nicht.
    func unwrappingListParagraphs(in html: String) -> String {
        let inlineElements = "a|abbr|b|br|cite|code|del|em|i|ins|kbd|mark|q|s"
            + "|samp|small|span|strong|sub|sup|u|var"
        let inlineContent = #"(?:[^<]|</?(?:\#(inlineElements))(?:\s[^>]*)?/?>)*"#
        let pattern = #"<li([^>]*)>\s*<p[^>]*>(\#(inlineContent))</p>\s*</li>"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return html
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return expression.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: "<li$1>$2</li>"
        )
    }

    private func nextRTFControlWord(
        in bytes: [UInt8],
        after index: Int
    ) -> (word: String, end: Int, parameter: Int?)? {
        var next = index
        while next < bytes.count,
              bytes[next] == 0x20 || bytes[next] == 0x09
                || bytes[next] == 0x0A || bytes[next] == 0x0D {
            next += 1
        }
        return rtfControlWord(in: bytes, at: next)
    }

    private func rtfControlWord(
        in bytes: [UInt8],
        at index: Int
    ) -> (word: String, end: Int, parameter: Int?)? {
        guard index + 1 < bytes.count,
              bytes[index] == 0x5C,
              isASCIIAlpha(bytes[index + 1]) else {
            return nil
        }

        var end = index + 1
        while end < bytes.count, isASCIIAlpha(bytes[end]) {
            end += 1
        }
        let word = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
        let parameterStart = end
        if end < bytes.count, bytes[end] == 0x2D {
            end += 1
        }
        while end < bytes.count, bytes[end] >= 0x30, bytes[end] <= 0x39 {
            end += 1
        }
        let parameter: Int?
        if end > parameterStart,
           let value = Int(String(decoding: bytes[parameterStart..<end], as: UTF8.self)) {
            parameter = value
        } else {
            parameter = nil
        }
        return (word, end, parameter)
    }

    private func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private func warnings(
        inputURL: URL,
        kind: InputFormat,
        referencedResourceNames: Set<String>,
        fileManager: FileManager
    ) -> [ConversionWarning] {
        guard kind == .rtfd else {
            if ColoredTextMarker.containsChromaticText(inRTF: inputURL) {
                return [.richTextColorNotPreserved]
            }
            return []
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: inputURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { url in
            guard url.lastPathComponent != "TXT.rtf",
                  !referencedResourceNames.contains(url.lastPathComponent) else {
                return nil
            }
            return .richTextAttachmentNotRepresented(url.lastPathComponent)
        }.sorted { $0.message < $1.message }
    }
}

/// Quellkompatibler Alias für Aufrufer der ursprünglichen RTFD-API.
public typealias RTFDConverter = RichTextConverter

private extension UInt8 {
    var isASCIIDigit: Bool {
        self >= 0x30 && self <= 0x39
    }
}
