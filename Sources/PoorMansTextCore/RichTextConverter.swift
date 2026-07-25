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

/// RTF und RTFD behalten getrennte Importwege, liefern aber dasselbe gestagte Ergebnis.
struct RichTextAdapter: DocumentConversionAdapter {
    let supportedFormats: Set<InputFormat> = [.rtf, .rtfd]

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
            if hasRTFFile, try hasRTFHeader(at: rtfURL) {
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

        if try hasRTFHeader(at: inputURL) {
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
        let htmlURL = workDirectory.appendingPathComponent("document.html")
        let emptyParagraphMarker = inputKind == .rtf
            ? "POORMANSTEXTEMPTY\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            : nil
        try createHTML(
            from: inputURL,
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
            inputURL: inputURL,
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
            let result: ProcessResult
            do {
                result = try ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/textutil"),
                    arguments: ["-convert", "html", "-output", htmlURL.path, textutilInput.path],
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

    private func hasRTFHeader(at url: URL) throws -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = [UInt8](try handle.read(upToCount: 32) ?? Data())
            let signature = [UInt8](#"{\rtf"#.utf8)
            guard bytes.starts(with: signature) else {
                return false
            }

            // `\rtf` ist ein Steuerwort mit verpflichtender Versionszahl.
            let versionStart = signature.count
            return versionStart < bytes.count && bytes[versionStart].isASCIIDigit
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
    }

    /// Schützt direkt aufeinanderfolgende `\\par`-Steuerwörter vor Pandocs
    /// Zusammenfaltung. Escapte Backslashes werden dabei nicht als Steuerwort
    /// interpretiert; das Quelldokument selbst bleibt unverändert.
    private func preservingEmptyRTFParagraphs(in data: Data, marker: String) -> Data {
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
                let binaryEnd = min(binaryStart + byteCount, bytes.count)
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
