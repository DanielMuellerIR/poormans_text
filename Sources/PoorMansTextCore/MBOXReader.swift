import Foundation

/// Liest den gemeinsamen zeilenorientierten Teil von RFC-4155-/mboxo-/mboxrd-
/// Archiven. From-Quotierung bleibt erhalten: Ihre Variante ist nicht erkennbar.
enum MBOXReader {
    static let maximumArchiveBytes = 512 * 1_048_576
    static let maximumLineBytes = 1_048_576

    struct Message {
        let index: Int
        let envelope: String
        let data: Data
        let hasQuotedFrom: Bool
    }

    static func isEnvelope(_ line: Data) -> Bool {
        guard line.starts(with: Data("From ".utf8)), line.count <= 4096, let text = String(data: line, encoding: .ascii) else { return false }
        let pattern = #"^From [!-~]+ (Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})(?: ([A-Za-z]{1,5}|[+-][0-9]{4}))? ([0-9]{4})(?: remote from [!-~]+)?$"#
        guard let match = text.range(of: pattern, options: .regularExpression), match == text.startIndex..<text.endIndex else { return false }
        let fields = text.split(separator: " ")
        guard let day = Int(fields[4]), (1...31).contains(day) else { return false }
        let time = fields[5].split(separator: ":").compactMap { Int($0) }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let yearIndex = fields[6].count == 4 && fields[6].utf8.allSatisfy({ (48...57).contains($0) }) ? 6 : 7
        guard let month = months.firstIndex(of: String(fields[3])), let year = Int(fields[yearIndex]), year > 0 else { return false }
        let date = DateComponents(year: year, month: month + 1, day: day)
        return date.isValidDate(in: Calendar(identifier: .gregorian)) && time.count == 3 && time[0] < 24 && time[1] < 60 && time[2] <= 60
    }

    static func validateHeaders(_ data: Data) throws {
        let (headers, _) = try MIMEMessage.splitHeaders(data)
        let names = Set(headers.map(\.name))
        guard !names.isDisjoint(with: ["from", "to", "subject", "date", "message-id", "mime-version", "content-type"]) else {
            throw ImportFailure("an MBOX separator is not followed by recognizable mail headers")
        }
        guard !names.contains("content-length") else {
            throw ImportFailure("Content-Length MBOX variants are not supported; export a separator-based MBOX archive")
        }
    }

    static func read(_ url: URL, consume: (Message) throws -> Void) throws {
        var line = Data()
        var message = Data()
        var envelope: String?
        var count = 0
        var quoted = false
        var inBody = false
        var previousWasEmpty = false
        var suspectHeaderStart: Int?

        func emit() throws {
            guard let envelope else { return }
            try validateHeaders(message)
            guard count < CollectionLimits.maximumDocuments else { throw ImportFailure("the MBOX exceeds its message limit") }
            count += 1
            // Genau eine leere Archiv-Trennzeile entfernen, niemals beliebig viele
            // Körperzeilen. MIME-Inhalte behalten ihre ursprünglichen Zeilenenden.
            if previousWasEmpty {
                if message.suffix(2) == Data([13, 10]) { message.removeLast(2) }
                else if message.last == 10 { message.removeLast() }
            }
            try consume(.init(index: count, envelope: envelope, data: message, hasQuotedFrom: quoted))
        }

        func acceptLine(_ raw: Data) throws {
            try ConversionExecution.check()
            var content = raw
            if content.last == 10 {
                content.removeLast()
                if content.last == 13 { content.removeLast() }
            }
            guard !content.contains(13) else { throw ImportFailure("bare CR line endings are not supported in MBOX") }
            if isEnvelope(content) {
                guard envelope == nil || inBody && previousWasEmpty else {
                    throw ImportFailure("an ambiguous MBOX separator is not preceded by a complete message and empty line")
                }
                try emit()
                envelope = String(decoding: content, as: UTF8.self)
                message = Data()
                quoted = false
                inBody = false
                suspectHeaderStart = nil
            } else {
                guard envelope != nil else { throw ImportFailure("the MBOX does not start with a valid From separator") }
                guard raw.count <= MIMEMessage.maximumSourceBytes - message.count else { throw ImportFailure("an MBOX message exceeds its size limit") }
                if !inBody {
                    guard raw.count <= MIMEMessage.maximumHeaderBytes + 4 - message.count else { throw ImportFailure("MBOX message headers exceed their size limit") }
                    if content.isEmpty {
                        try validateHeaders(message + raw)
                        inBody = true
                    }
                }
                if inBody {
                    if content.isEmpty, let start = suspectHeaderStart {
                        let candidate = Data(message.dropFirst(start)) + raw
                        if let (headers, _) = try? MIMEMessage.splitHeaders(candidate),
                           !Set(headers.map(\.name)).isDisjoint(with: ["from", "to", "subject", "date", "message-id", "mime-version", "content-type"]) {
                            throw ImportFailure("an unrecognized From separator is followed by mail headers; the MBOX boundary is ambiguous")
                        }
                        suspectHeaderStart = nil
                    }
                    if content.starts(with: Data("From ".utf8)), previousWasEmpty {
                        suspectHeaderStart = message.count + raw.count
                    }
                    if let start = suspectHeaderStart, message.count - start > MIMEMessage.maximumHeaderBytes {
                        suspectHeaderStart = nil
                    }
                    let unquoted = content.drop(while: { $0 == 62 })
                    if unquoted.count < content.count && unquoted.starts(with: Data("From ".utf8)) { quoted = true }
                }
                message.append(raw)
            }
            previousWasEmpty = content.isEmpty
        }

        try VerifiedFileStaging.withVerifiedSource(at: url, maximumBytes: maximumArchiveBytes, describedAs: "the MBOX archive") { source, _ in
            _ = try source.readChunks(maximumBytes: maximumArchiveBytes, chunkSize: 65_536,
                budgetExceeded: { ImportFailure("the MBOX exceeds its archive size limit") }) { bytes in
                var start = 0
                for offset in bytes.indices where bytes[offset] == 10 {
                    guard offset + 1 - start <= maximumLineBytes - line.count else { throw ImportFailure("an MBOX line exceeds its size limit") }
                    line.append(contentsOf: bytes[start...offset])
                    try acceptLine(line)
                    line.removeAll(keepingCapacity: true)
                    start = offset + 1
                }
                guard bytes.count - start <= maximumLineBytes - line.count else { throw ImportFailure("an MBOX line exceeds its size limit") }
                line.append(contentsOf: bytes[start..<bytes.count])
                return true
            }
            if !line.isEmpty { try acceptLine(line) }
            try emit()
        }
    }
}
