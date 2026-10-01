import Foundation

/// Begrenzter MIME-Leser. Fremde Dateinamen bleiben Daten und werden nie als Pfad geöffnet.
enum MIMEMessage {
    static let maximumSourceBytes = 64 * 1_024 * 1_024
    static let maximumHeaderBytes = 256 * 1_024
    static let maximumParts = 1_024
    static let maximumDepth = 32

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    struct Header: Equatable {
        let name: String
        let value: String
    }

    struct Part {
        let headers: [Header]
        let mediaType: String
        let parameters: [String: String]
        let disposition: String
        let dispositionParameters: [String: String]
        let sourceData: Data
        let body: Data
        let children: [Part]

        func header(_ name: String) -> String? {
            headers.first { $0.name == name.lowercased() }?.value
        }

        var filename: String? { dispositionParameters["filename"] ?? parameters["name"] }

        func text() throws -> String {
            let charset = parameters["charset"] ?? "us-ascii"
            guard let encoding = String.Encoding(ianaCharSetName: charset),
                  let text = String(data: body, encoding: encoding), !text.contains("\0") else {
                throw Failure(reason: "the mail text cannot be decoded using charset \(charset)")
            }
            return text
        }
    }

    static func read(_ data: Data, emlx: Bool = false) throws -> Part {
        guard data.count <= maximumSourceBytes else { throw Failure(reason: "the mail exceeds the size limit") }
        let message: Data
        if emlx {
            guard let newline = data.firstIndex(of: 10), data.distance(from: data.startIndex, to: newline) <= 20 else {
                throw Failure(reason: "the Apple Mail byte-count line is missing")
            }
            let countLine = String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !countLine.isEmpty, countLine.utf8.allSatisfy({ (48...57).contains($0) }),
                  let count = Int(countLine), count > 0, count <= data.count - data.distance(from: data.startIndex, to: newline) - 1 else {
                throw Failure(reason: "the Apple Mail byte count is invalid or truncated")
            }
            let start = data.index(after: newline)
            message = Data(data[start..<data.index(start, offsetBy: count)])
        } else {
            message = data
        }
        var count = 0
        var parsedBytes = 0
        return try parse(message, defaultMediaType: "text/plain", depth: 0, count: &count, parsedBytes: &parsedBytes)
    }

    private static func parse(_ data: Data, defaultMediaType: String, depth: Int, count: inout Int, parsedBytes: inout Int) throws -> Part {
        try ConversionExecution.check()
        count += 1
        parsedBytes += data.count
        guard depth <= maximumDepth, count <= maximumParts else { throw Failure(reason: "the MIME nesting or part limit was exceeded") }
        // Verschachtelte Multipart-Kopien zählen mehrfach, bevor weiterer Speicher belegt wird.
        guard parsedBytes <= maximumSourceBytes * 2 else { throw Failure(reason: "the expanded MIME parsing budget was exceeded") }
        let (headers, rawBody) = try splitHeaders(data)
        func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }
        for name in ["content-type", "content-transfer-encoding", "content-disposition"] {
            guard headers.filter({ $0.name == name }).count <= 1 else { throw Failure(reason: "duplicate MIME control header: \(name)") }
        }
        let contentType = try parameterized(header("content-type") ?? defaultMediaType)
        let disposition = try parameterized(header("content-disposition") ?? "")
        let body = try decodeTransfer(rawBody, encoding: header("content-transfer-encoding") ?? "7bit")
        var children = [Part]()
        if contentType.0.hasPrefix("multipart/") {
            guard let boundary = contentType.1["boundary"], !boundary.isEmpty,
                  boundary.utf8.count <= 70, boundary.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }), !boundary.hasSuffix(" ") else {
                throw Failure(reason: "the multipart boundary is invalid or missing")
            }
            for child in try multipart(body, boundary: boundary) {
                children.append(try parse(child, defaultMediaType: contentType.0 == "multipart/digest" ? "message/rfc822" : "text/plain",
                                          depth: depth + 1, count: &count, parsedBytes: &parsedBytes))
            }
        }
        return Part(headers: headers, mediaType: contentType.0, parameters: contentType.1,
                    disposition: disposition.0, dispositionParameters: disposition.1,
                    sourceData: data,
                    body: children.isEmpty ? body : Data(), children: children)
    }

    static func splitHeaders(_ data: Data) throws -> ([Header], Data) {
        let bytes = [UInt8](data.prefix(maximumHeaderBytes + 4))
        var position = 0
        var headers = [Header]()
        while position < bytes.count {
            try ConversionExecution.check()
            let start = position
            while position < bytes.count, bytes[position] != 10 { position += 1 }
            guard position < bytes.count else { throw Failure(reason: "the mail header separator is missing or too large") }
            var end = position
            if end > start, bytes[end - 1] == 13 { end -= 1 }
            position += 1
            if start == end {
                return (headers, Data(data.dropFirst(position)))
            }
            guard position <= maximumHeaderBytes else { throw Failure(reason: "the mail headers exceed the size limit") }
            let lineBytes = bytes[start..<end]
            guard !lineBytes.contains(0), !lineBytes.contains(13),
                  let line = String(data: Data(lineBytes), encoding: .utf8) else {
                throw Failure(reason: "the mail headers contain invalid text")
            }
            if lineBytes.first == 32 || lineBytes.first == 9 {
                guard let previous = headers.popLast() else { throw Failure(reason: "a mail header continuation has no preceding field") }
                headers.append(Header(name: previous.name, value: previous.value + " " + line.trimmingCharacters(in: .whitespaces)))
            } else {
                guard let colon = line.firstIndex(of: ":") else { throw Failure(reason: "a mail header has no colon") }
                let name = String(line[..<colon])
                guard !name.isEmpty, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 58 }) else {
                    throw Failure(reason: "a mail header field name is invalid")
                }
                headers.append(Header(name: name.lowercased(), value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        throw Failure(reason: "the mail header separator is missing")
    }

    private static func multipart(_ data: Data, boundary: String) throws -> [Data] {
        let bytes = [UInt8](data)
        let marker = Array(("--" + boundary).utf8)
        var position = 0
        var partStart: Int?
        var parts = [Data]()
        var closed = false
        while position < bytes.count {
            try ConversionExecution.check()
            let start = position
            while position < bytes.count, bytes[position] != 10 { position += 1 }
            var end = position
            if end > start, bytes[end - 1] == 13 { end -= 1 }
            if position < bytes.count { position += 1 }
            var line = Array(bytes[start..<end])
            while line.last == 32 || line.last == 9 { line.removeLast() }
            let closing = line == marker + [45, 45]
            guard line == marker || closing else { continue }
            if let partStart {
                var partEnd = start
                // Die Zeilenendung unmittelbar vor dem Delimiter gehört zum Delimiter (RFC 2046).
                if partEnd > partStart, bytes[partEnd - 1] == 10 { partEnd -= 1 }
                if partEnd > partStart, bytes[partEnd - 1] == 13 { partEnd -= 1 }
                // Bei einem leeren Körper darf die gemeinsame CRLF die Header-Leerzeile nicht entfernen.
                let headerPrefix = Data(bytes[partStart..<min(start, partStart + maximumHeaderBytes + 4)])
                let separators = [Data([13, 10, 13, 10]), Data([10, 10])]
                    .compactMap { headerPrefix.range(of: $0) }
                let separator = separators.min { $0.lowerBound < $1.lowerBound }
                if separator?.upperBound == start - partStart || headerPrefix == Data([10]) || headerPrefix == Data([13, 10]) {
                    partEnd = start
                }
                guard parts.count < maximumParts else { throw Failure(reason: "the MIME part limit was exceeded") }
                parts.append(Data(bytes[partStart..<partEnd]))
            }
            if closing { closed = true; break }
            partStart = position
        }
        guard closed, !parts.isEmpty else { throw Failure(reason: "the multipart mail is incomplete or empty") }
        return parts
    }

    static func decodeTransfer(_ data: Data, encoding: String) throws -> Data {
        switch encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "7bit", "8bit", "binary": return data
        case "base64":
            let compact = Data(data.filter { ![9, 10, 13, 32].contains($0) })
            guard let decoded = Data(base64Encoded: compact) else { throw Failure(reason: "the mail contains invalid Base64") }
            return decoded
        case "quoted-printable": return try quotedPrintable(data)
        default: throw Failure(reason: "the mail uses an unsupported transfer encoding")
        }
    }

    static func decodedHeader(_ value: String) throws -> String {
        let expression = try NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#)
        let text = value as NSString
        var output = ""
        var cursor = 0
        var previousWasEncoded = false
        for match in expression.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            try ConversionExecution.check()
            let between = text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Zwischen benachbarten encoded words ist Faltungs-Whitespace kein Inhalt (RFC 2047).
            if !previousWasEncoded || !between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output += between }
            let charset = text.substring(with: match.range(at: 1))
            let kind = text.substring(with: match.range(at: 2)).lowercased()
            let payload = text.substring(with: match.range(at: 3))
            let bytes: Data
            if kind == "b" {
                guard let decoded = Data(base64Encoded: payload) else { throw Failure(reason: "a mail header contains invalid Base64") }
                bytes = decoded
            } else {
                bytes = try quotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            guard let encoding = String.Encoding(ianaCharSetName: charset), let decoded = String(data: bytes, encoding: encoding) else {
                throw Failure(reason: "a mail header cannot be decoded using charset \(charset)")
            }
            output += decoded
            cursor = match.range.location + match.range.length
            previousWasEncoded = true
        }
        output += text.substring(from: cursor)
        return output
    }

    private static func quotedPrintable(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var output = Data()
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 65 + 10
            case 97...102: return byte - 97 + 10
            default: return nil
            }
        }
        while index < bytes.count {
            if index % 4096 == 0 { try ConversionExecution.check() }
            if bytes[index] != 61 { output.append(bytes[index]); index += 1; continue }
            if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
            if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
            guard index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else {
                throw Failure(reason: "the mail contains invalid quoted-printable data")
            }
            output.append(high * 16 + low)
            index += 3
        }
        return output
    }

    static func parameterized(_ value: String) throws -> (String, [String: String]) {
        var fields = [String]()
        var field = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped { field.append(character); escaped = false; continue }
            if quoted, character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if character == ";", !quoted { fields.append(field); field = "" } else { field.append(character) }
        }
        guard !quoted, !escaped else { throw Failure(reason: "a MIME parameter has an unterminated quote") }
        fields.append(field)
        guard fields.count <= 257 else { throw Failure(reason: "the MIME parameter limit was exceeded") }
        let kind = fields.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        var raw = [String: String]()
        for field in fields {
            guard let equal = field.firstIndex(of: "=") else { throw Failure(reason: "a MIME parameter has no value") }
            let name = field[..<equal].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, raw[name] == nil else { throw Failure(reason: "a MIME parameter is empty or duplicated") }
            raw[name] = field[field.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        }
        var result = raw.filter { !$0.key.contains("*") }
        for name in Set(raw.keys.map { String($0.prefix { $0 != "*" }) }) {
            let segmentKeys = raw.keys.filter { $0.hasPrefix(name + "*") && $0 != name + "*" }
            if let extended = raw[name + "*"] {
                guard segmentKeys.isEmpty else { throw Failure(reason: "an extended MIME parameter has conflicting continuations") }
                result[name] = try extendedParameter(extended)
                continue
            }
            var pieces = [String]()
            var flags = [Bool]()
            var encoded = false
            var index = 0
            while let piece = raw[name + "*\(index)"] ?? raw[name + "*\(index)*"] {
                if raw[name + "*\(index)*"] != nil { encoded = true }
                flags.append(raw[name + "*\(index)*"] != nil)
                pieces.append(piece)
                index += 1
            }
            guard segmentKeys.count == pieces.count else { throw Failure(reason: "MIME parameter continuations are ambiguous or have a gap") }
            if !pieces.isEmpty {
                if encoded {
                    guard flags.first == true else { throw Failure(reason: "an encoded MIME continuation has no leading charset") }
                    // Nur mit Stern markierte Segmente haben Prozent-Escapes (RFC 2231).
                    let combined = zip(pieces, flags).map { piece, flag in
                        flag ? piece : piece.replacingOccurrences(of: "%", with: "%25")
                    }.joined()
                    result[name] = try extendedParameter(combined)
                } else { result[name] = pieces.joined() }
            }
        }
        return (kind, result)
    }

    private static func extendedParameter(_ value: String) throws -> String {
        let fields = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let encoding = String.Encoding(ianaCharSetName: String(fields[0])) else {
            throw Failure(reason: "an extended MIME parameter has no valid charset")
        }
        let bytes = Array(fields[2].utf8)
        var data = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count,
                      let byte = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else {
                    throw Failure(reason: "an extended MIME parameter has an invalid escape")
                }
                data.append(byte); index += 3
            } else { data.append(bytes[index]); index += 1 }
        }
        guard let text = String(data: data, encoding: encoding) else { throw Failure(reason: "an extended MIME parameter cannot be decoded") }
        return text
    }
}
