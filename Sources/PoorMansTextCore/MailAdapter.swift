import Foundation

struct MailAdapter: DocumentConversionAdapter {
    var supportedFormatDescriptors: [SupportedFormat] {
        [SupportedFormat(format: .eml, fileExtensions: ["eml", "emlx"], containerKind: .file, requiredTools: [.pandoc])]
    }

    private static let priority = 180

    func inspectInput(at inputURL: URL) throws -> AdapterInputDetection {
        let namedMail = ["eml", "emlx"].contains(inputURL.pathExtension.lowercased())
        let prefix: Data
        do {
            prefix = try VerifiedFileStaging.prefix(of: inputURL, maximumBytes: MIMEMessage.maximumSourceBytes,
                prefixBytes: MIMEMessage.maximumHeaderBytes + 32, describedAs: "the mail source")
        } catch {
            return namedMail ? .invalid(format: .eml, priority: Self.priority, reason: error.localizedDescription) : .noMatch
        }
        do {
            let message = try Self.messagePrefix(prefix, requireAppleMail: inputURL.pathExtension.lowercased() == "emlx")
            let (headers, _) = try MIMEMessage.splitHeaders(message)
            let names = Set(headers.map(\.name))
            let known: Set<String> = ["from", "to", "subject", "date", "message-id", "mime-version", "content-type"]
            let identified = namedMail ? !names.isDisjoint(with: known)
                : names.contains("from") && !names.isDisjoint(with: ["to", "subject", "message-id"])
                    || names.contains("mime-version") && names.contains("content-type")
            guard identified else {
                return namedMail ? .invalid(format: .eml, priority: Self.priority, reason: "the file carries no mail headers") : .noMatch
            }
            return .match(AdapterInputInspection(format: .eml, priority: Self.priority, expectedWarnings: []))
        } catch {
            return namedMail ? .invalid(format: .eml, priority: Self.priority, reason: error.localizedDescription) : .noMatch
        }
    }

    func convert(_ context: AdapterConversionContext) throws -> StagedConversionResult {
        let part: MIMEMessage.Part
        do {
            let data = try VerifiedFileStaging.contents(of: context.resolvedInputURL,
                maximumBytes: MIMEMessage.maximumSourceBytes, describedAs: "the mail source")
            let emlx = Self.hasAppleMailCount(data)
            guard context.inputURL.pathExtension.lowercased() != "emlx" || emlx else {
                throw MIMEMessage.Failure(reason: "the Apple Mail byte-count line is missing")
            }
            part = try MIMEMessage.read(data, emlx: emlx)
        } catch let error as ConversionError { throw error }
        catch { throw ConversionError.invalidInput(context.inputURL, format: .eml, reason: error.localizedDescription) }

        let converted: StagedConversionResult
        let table: String
        let metadata: DocumentMetadata
        do {
            table = try Self.headerTable(part.headers)
            metadata = try Self.metadata(part.headers)
            converted = try MailBodyConverter.convert(part, context: context)
        } catch let error as MIMEMessage.Failure {
            throw ConversionError.invalidInput(context.inputURL, format: .eml, reason: error.reason)
        }
        try ConversionPostprocessor.prepend(table, to: context.stagedOutputDirectory.appendingPathComponent(converted.markdownRelativePath))
        return StagedConversionResult(markdownRelativePath: converted.markdownRelativePath,
            assetRelativePaths: converted.assetRelativePaths, warnings: converted.warnings, metadata: metadata)
    }

    private static func hasAppleMailCount(_ data: Data) -> Bool {
        guard let newline = data.prefix(22).firstIndex(of: 10) else { return false }
        let line = String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !line.isEmpty && line.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func messagePrefix(_ data: Data, requireAppleMail: Bool) throws -> Data {
        guard hasAppleMailCount(data) else {
            if requireAppleMail { throw MIMEMessage.Failure(reason: "the Apple Mail byte-count line is missing") }
            return data
        }
        guard let newline = data.firstIndex(of: 10),
              let count = Int(String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              count > 0, count <= MIMEMessage.maximumSourceBytes else {
            throw MIMEMessage.Failure(reason: "the Apple Mail byte count is invalid")
        }
        // Die Erkennung braucht nur die Header; die vollständige Bytezahl prüft erst der Leser.
        return Data(data.dropFirst(data.distance(from: data.startIndex, to: newline) + 1).prefix(count))
    }

    static func headerTable(_ headers: [MIMEMessage.Header]) throws -> String {
        var table = "| Header | Value |\n| --- | --- |\n"
        for header in headers {
            try ConversionExecution.check()
            let value = try MIMEMessage.decodedHeader(header.value)
            let singleLine = value.components(separatedBy: .controlCharacters).joined(separator: " ")
                .split(whereSeparator: \.isNewline).joined(separator: " ")
            table += "| " + MarkdownEscaping.inlineLiteral(header.name) + " | " + MarkdownEscaping.inlineLiteral(singleLine) + " |\n"
        }
        return table + "\n"
    }

    static func metadata(_ headers: [MIMEMessage.Header]) throws -> DocumentMetadata {
        func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }
        func decoded(_ name: String) throws -> String? {
            try header(name).map(MIMEMessage.decodedHeader)
        }
        let subject = try decoded("subject")
        let from = try decoded("from")
        let date: Date?
        if let value = header("date") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            var parsed: Date?
            for format in ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z"] {
                formatter.dateFormat = format
                if let result = formatter.date(from: value) { parsed = result; break }
            }
            date = parsed
        } else { date = nil }
        return DocumentMetadata(title: subject, author: from, subject: subject, created: date)
    }
}
