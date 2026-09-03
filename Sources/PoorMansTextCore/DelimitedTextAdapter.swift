import Foundation

/// CSV und TSV als Ein-Blatt-Arbeitsmappe über den gemeinsamen Tabellen-Renderer.
///
/// Reiner Text lässt sich am Inhalt nicht als Tabelle erkennen — jede
/// Textdatei „ist“ eine einspaltige CSV. Deshalb ist dies der einzige Adapter,
/// der die Dateiendung verlangt: `.csv` oder `.tsv`. Der Inhalt muss danach
/// trotzdem Text sein (kein NUL-Byte, dekodierbar), sonst gilt die Datei als
/// ungültig.
struct DelimitedTextAdapter: DocumentConversionAdapter {
    let supportedFormatDescriptors: [SupportedFormat] = [
        SupportedFormat(
            format: .csv,
            fileExtensions: ["csv", "tsv"],
            containerKind: .file,
            requiredTools: []
        ),
    ]

    private static let detectionPriority = 100

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let fileExtension = inputURL.pathExtension.lowercased()
        guard fileExtension == "csv" || fileExtension == "tsv" else {
            return .noMatch
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .noMatch
        }
        do {
            let prefix = try VerifiedFileStaging.prefix(
                of: inputURL,
                maximumBytes: DelimitedTextLimits.maximumSourceBytes,
                prefixBytes: DelimitedTextLimits.inspectionBytes,
                describedAs: "the delimited text source"
            )
            let decoded = try DelimitedTextDecoder.decode(prefix, truncated: true)
            return .match(
                AdapterInputInspection(
                    format: .csv,
                    priority: Self.detectionPriority,
                    expectedWarnings: decoded.assumedEncoding ? [.delimitedTextEncodingAssumed] : []
                )
            )
        } catch {
            return .invalid(
                format: .csv,
                priority: Self.detectionPriority,
                reason: error.localizedDescription
            )
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        guard context.format == .csv else {
            throw ConversionError.unsupportedInput(context.inputURL)
        }
        let stagedInput = context.workDirectory.appendingPathComponent("verified-source.txt")
        do {
            try VerifiedFileStaging.stage(
                from: context.resolvedInputURL,
                to: stagedInput,
                maximumBytes: DelimitedTextLimits.maximumSourceBytes,
                describedAs: "the delimited text source"
            )
        } catch let error as VerifiedFileStaging.StagingError where error.kind == .source {
            throw ConversionError.invalidInput(context.inputURL, format: .csv, reason: error.reason)
        } catch let error as VerifiedFileStaging.StagingError {
            throw ConversionError.fileSystemFailure(error.reason)
        }

        let workbook: SpreadsheetWorkbook
        var warnings = [ConversionWarning]()
        do {
            let data = try Data(contentsOf: stagedInput, options: [.mappedIfSafe])
            let decoded = try DelimitedTextDecoder.decode(data, truncated: false)
            if decoded.assumedEncoding {
                warnings.append(.delimitedTextEncodingAssumed)
            }
            // Bei `.tsv` steht das Trennzeichen fest; bei `.csv` wird es aus
            // den ersten Zeilen bestimmt, weil deutsche Exporte meist `;` nutzen.
            let delimiter: Character = context.inputURL.pathExtension.lowercased() == "tsv"
                ? "\t"
                : DelimitedTextParser.sniffDelimiter(in: decoded.text)
            let rows = try DelimitedTextParser.parse(decoded.text, delimiter: delimiter)
            let sheetName = context.inputURL.deletingPathExtension().lastPathComponent
            workbook = SpreadsheetWorkbook(sheets: [SpreadsheetSheet(name: sheetName, rows: rows)])
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .csv,
                reason: error.localizedDescription
            )
        }

        let markdownName = context.inputURL.deletingPathExtension().lastPathComponent + ".md"
        let markdownURL = context.stagedOutputDirectory.appendingPathComponent(markdownName)
        let markdown: String
        do {
            markdown = try SpreadsheetMarkdownRenderer.render(
                workbook,
                sourceURL: context.inputURL,
                style: context.options.spreadsheetRendering
            )
        } catch {
            throw ConversionError.invalidInput(
                context.inputURL,
                format: .csv,
                reason: error.localizedDescription
            )
        }
        do {
            try Data(markdown.utf8).write(to: markdownURL, options: .atomic)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        return StagedConversionResult(
            markdownRelativePath: markdownName,
            assetRelativePaths: [],
            warnings: warnings
        )
    }
}

enum DelimitedTextLimits {
    static let maximumSourceBytes = 256 * 1_024 * 1_024
    static let inspectionBytes = 65_536
    static let maximumRows = 1_000_000
    static let maximumCells = 5_000_000
    static let maximumColumns = 16_384
}

/// Bestimmt die Kodierung: BOM zuerst, sonst strenges UTF-8, sonst Windows-1252
/// mit Hinweis. Ein NUL-Byte heißt Binärdatei.
enum DelimitedTextDecoder {
    struct Decoded {
        let text: String
        let assumedEncoding: Bool
    }

    static func decode(_ data: Data, truncated: Bool) throws -> Decoded {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return try decodeUTF8(data.dropFirst(3), truncated: truncated, strict: true)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return try decodeUTF16(data.dropFirst(2), encoding: .utf16LittleEndian, truncated: truncated)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return try decodeUTF16(data.dropFirst(2), encoding: .utf16BigEndian, truncated: truncated)
        }
        guard !data.contains(0) else {
            throw DelimitedTextError("the file contains binary data, not delimited text")
        }
        return try decodeUTF8(data[...], truncated: truncated, strict: false)
    }

    private static func decodeUTF8(_ bytes: Data.SubSequence, truncated: Bool, strict: Bool) throws -> Decoded {
        guard !bytes.contains(0) else {
            throw DelimitedTextError("the file contains binary data, not delimited text")
        }
        var slice = Data(bytes)
        // Ein abgeschnittenes Mehrbyte-Zeichen am Ende des Prüffensters ist
        // kein Kodierungsfehler; bis zu drei unvollständige Bytes fallen weg.
        for _ in 0..<(truncated ? 4 : 1) {
            if let text = String(data: slice, encoding: .utf8) {
                return Decoded(text: text, assumedEncoding: false)
            }
            guard truncated, !slice.isEmpty else {
                break
            }
            slice = slice.dropLast()
        }
        guard !strict, let text = String(data: Data(bytes), encoding: .windowsCP1252) else {
            throw DelimitedTextError("the file is neither valid UTF-8 nor Windows-1252 text")
        }
        return Decoded(text: text, assumedEncoding: true)
    }

    private static func decodeUTF16(_ bytes: Data.SubSequence, encoding: String.Encoding, truncated: Bool) throws -> Decoded {
        // Ein halbes Codeunit am Ende ist nur im abgeschnittenen Prüffenster
        // harmlos. In der vollständigen Datei ist es ein Defekt, der sonst
        // still ein Zeichen verlieren würde (Review-Fund 2026-09-03).
        guard bytes.count % 2 == 0 || truncated else {
            throw DelimitedTextError("the file has a UTF-16 byte-order mark but ends in half a character")
        }
        let even = bytes.count % 2 == 0 ? Data(bytes) : Data(bytes.dropLast())
        guard let text = String(data: even, encoding: encoding) else {
            throw DelimitedTextError("the file has a UTF-16 byte-order mark but invalid UTF-16 text")
        }
        return Decoded(text: text, assumedEncoding: false)
    }
}

/// RFC-4180-Leser: Anführungszeichen, verdoppelte Anführungszeichen und
/// Zeilenumbrüche innerhalb von Feldern; CRLF, LF und CR als Zeilenende.
enum DelimitedTextParser {
    static let candidateDelimiters: [Character] = [",", ";", "\t", "|"]

    /// Wählt das Trennzeichen, das in den ersten Zeilen am gleichmäßigsten
    /// vorkommt. Ohne Treffer bleibt das Komma, die Datei wird dann einspaltig.
    static func sniffDelimiter(in text: String) -> Character {
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).prefix(20)
        guard !lines.isEmpty else {
            return ","
        }
        var best: (delimiter: Character, count: Int)?
        for delimiter in candidateDelimiters {
            let counts = lines.map { line in line.filter { $0 == delimiter }.count }
            guard let first = counts.first, first > 0 else {
                continue
            }
            // Gleich viele Trennzeichen je Zeile ist das stärkste Zeichen;
            // ein Feld mit Zeilenumbruch stört das nur selten.
            let consistent = counts.allSatisfy { $0 == first }
            let score = consistent ? first * 1_000 : counts.min() ?? 0
            if best == nil || score > best!.count {
                best = (delimiter, score)
            }
        }
        return best?.delimiter ?? ","
    }

    static func parse(_ text: String, delimiter: Character) throws -> [[SpreadsheetCell]] {
        var rows = [[SpreadsheetCell]]()
        var row = [SpreadsheetCell]()
        var field = ""
        var inQuotes = false
        var cellCount = 0
        var iterator = text.makeIterator()

        func finishField() throws {
            row.append(field.isEmpty ? .empty : SpreadsheetCell(value: .string(field), displayText: field, formula: nil))
            field = ""
            cellCount += 1
            guard row.count <= DelimitedTextLimits.maximumColumns else {
                throw DelimitedTextError("the file exceeds \(DelimitedTextLimits.maximumColumns) columns")
            }
            guard cellCount <= DelimitedTextLimits.maximumCells else {
                throw DelimitedTextError("the file exceeds \(DelimitedTextLimits.maximumCells) cells")
            }
        }
        func finishRow() throws {
            try finishField()
            rows.append(row)
            row = []
            guard rows.count <= DelimitedTextLimits.maximumRows else {
                throw DelimitedTextError("the file exceeds \(DelimitedTextLimits.maximumRows) rows")
            }
        }
        var lookahead: Character? = iterator.next()
        while let character = lookahead {
            lookahead = iterator.next()
            if inQuotes {
                if character == "\"" {
                    if lookahead == "\"" {
                        field.append("\"")
                        lookahead = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                try finishField()
            case "\r\n", "\r", "\n":
                // Swift fasst CR+LF zu einem Zeichen zusammen; alle drei Formen
                // beenden die Zeile.
                try finishRow()
            default:
                field.append(character)
            }
        }
        // Ein am Dateiende noch offenes Anführungsfeld ist ein Syntaxfehler;
        // stillschweigend abzuschließen würde Trennzeichen und Zeilen verfälschen.
        guard !inQuotes else {
            throw DelimitedTextError("the file ends inside a quoted field")
        }
        // Die letzte Zeile ohne Zeilenende zählt; eine leere Datei ergibt keine Zeile.
        if !field.isEmpty || !row.isEmpty {
            try finishRow()
        }
        return rows
    }
}

struct DelimitedTextError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
