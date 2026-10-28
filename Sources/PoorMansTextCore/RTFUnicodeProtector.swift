import Foundation
import CoreFoundation

/// Schützt Unicode und schriftabhängige ANSI-Codierungen vor Pandocs RTF-Leser.
/// Nur die temporäre Eingabe erhält ASCII-Marker; im HTML werden daraus sichere
/// Zeichenreferenzen. So bleiben Bilder und der bestehende RTF-Import erhalten.
struct RTFUnicodeProtector {
    struct Failure: Error {
        let reason: String
    }

    let data: Data
    private let prefix: String

    private struct State {
        var fallbackCount = 1
        var ignored = false
        var opaque = false
        var fontTable = false
        var font: Int?
        var codepage: UInt32 = 1252
    }

    private struct FontEncoding {
        var charset: Int?
        var codepage: UInt32?
    }

    static func protect(_ source: Data) throws -> Self {
        let bytes = Array(source)
        var prefix: String
        repeat { prefix = "POORMANSTEXTUNICODE" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        while source.range(of: Data(prefix.utf8)) != nil
        var result = Data()
        result.reserveCapacity(bytes.count)
        var state = State()
        var groupStates = [State]()
        var defaultFont = 0
        var fonts = [Int: FontEncoding]()
        var raw = Data()
        var rawSource = Data()
        var remainingFallback = 0
        var pending: (unit: UInt16, range: Range<Int>)?
        var unicodeCount = 0
        var index = 0
        var nextCancellationCheck = 0

        func fail(_ detail: String) -> Failure { Failure(reason: "RTF Unicode: " + detail) }
        func requireCompletePair() throws {
            guard pending == nil else { throw fail("a high surrogate has no adjacent low surrogate") }
        }
        func marker(_ scalar: UInt32) -> Data { Data("{\(prefix)\(String(scalar, radix: 16))END}".utf8) }
        func alpha(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        func appendLiteral(_ byte: UInt8, to output: inout Data) {
            // Pandoc liest einen Apostroph direkt nach \'hh fälschlich als
            // weiteren Hex-Escape. Die gleichwertige Schreibweise trennt ihn ab.
            if byte == 39 { output.append(contentsOf: #"\'27"#.utf8) }
            else { output.append(byte) }
        }
        func flush() throws {
            guard !raw.isEmpty else {
                result.append(rawSource)
                rawSource.removeAll(keepingCapacity: true)
                return
            }
            if raw.contains(where: { $0 >= 128 }) {
                let font = fonts[state.font ?? defaultFont]
                let codepage = font?.codepage ?? font?.charset.flatMap(RTFCodepage.fromCharset) ?? state.codepage
                let encoding = CFStringConvertWindowsCodepageToEncoding(codepage)
                guard encoding != kCFStringEncodingInvalidId,
                      let text = String(data: raw, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) else {
                    throw fail("text in code page \(codepage) cannot be decoded")
                }
                for (offset, scalar) in text.unicodeScalars.enumerated() {
                    if offset % 4096 == 0 { try ConversionExecution.check() }
                    if scalar.value >= 128 { result.append(marker(scalar.value)) }
                    else if [92, 123, 125].contains(scalar.value) {
                        result.append(92)
                        result.append(UInt8(scalar.value))
                    } else { appendLiteral(UInt8(scalar.value), to: &result) }
                    guard result.count <= RichTextLimits.maximumSourceSize else { throw fail("the normalized input exceeds the size limit") }
                }
            } else { result.append(rawSource) }
            raw.removeAll(keepingCapacity: true)
            rawSource.removeAll(keepingCapacity: true)
        }
        func literal(_ value: UInt8, source: Range<Int>, escaped: Bool) throws {
            if state.ignored || state.opaque {
                if escaped { result.append(contentsOf: bytes[source]) }
                else { appendLiteral(value, to: &result) }
                return
            }
            if remainingFallback > 0 { remainingFallback -= 1; return }
            try requireCompletePair()
            raw.append(value)
            if escaped { rawSource.append(contentsOf: bytes[source]) }
            else { appendLiteral(value, to: &rawSource) }
        }

        while index < bytes.count {
            if index >= nextCancellationCheck {
                try ConversionExecution.check()
                nextCancellationCheck = index + 4096
            }
            guard result.count <= RichTextLimits.maximumSourceSize else { throw fail("the normalized input exceeds the size limit") }
            let start = index
            let byte = bytes[index]
            index += 1
            if byte == 123 || byte == 125 {
                try flush()
                remainingFallback = 0
                if byte == 123 {
                    guard groupStates.count < 256 else { throw fail("the group nesting is too deep") }
                    groupStates.append(state)
                } else {
                    guard let parent = groupStates.popLast() else { throw fail("an RTF group end is unmatched") }
                    state = parent
                }
                result.append(byte)
                continue
            }
            if byte == 13 || byte == 10 {
                if raw.isEmpty { result.append(byte) }
                else { rawSource.append(byte) }
                continue
            }
            guard byte == 92 else {
                try literal(byte, source: start..<index, escaped: false)
                continue
            }
            guard index < bytes.count else { throw fail("a control is truncated") }
            let first = bytes[index]
            index += 1
            guard alpha(first) else {
                if first == 39 {
                    guard index + 2 <= bytes.count,
                          let value = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16) else {
                        throw fail("a hexadecimal escape is invalid")
                    }
                    index += 2
                    try literal(value, source: start..<index, escaped: true)
                    continue
                }
                if first == 92 || first == 123 || first == 125 {
                    try literal(first, source: start..<index, escaped: true)
                    continue
                }
                try flush()
                // Ignorierte Destinationen tragen nichts zum sichtbaren UTF-16-Strom bei.
                if first == 42 { state.ignored = true }
                if state.ignored { result.append(contentsOf: bytes[start..<index]); continue }
                if remainingFallback > 0 { remainingFallback -= 1; continue }
                if first != 13 && first != 10 { try requireCompletePair() }
                result.append(contentsOf: bytes[start..<index])
                continue
            }
            try flush()
            let wordStart = index - 1
            while index < bytes.count, alpha(bytes[index]) { index += 1 }
            let word = String(decoding: bytes[wordStart..<index], as: UTF8.self)
            let numberStart = index
            if index < bytes.count, bytes[index] == 45 { index += 1 }
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            let parameter: Int?
            if index > numberStart {
                guard index - numberStart <= 11,
                      let value = Int(String(decoding: bytes[numberStart..<index], as: UTF8.self)) else {
                    throw fail("a control parameter is invalid")
                }
                parameter = value
            } else { parameter = nil }
            if index < bytes.count, bytes[index] == 32 { index += 1 }
            if word == "bin" {
                guard let count = parameter, count >= 0, count <= bytes.count - index else {
                    throw fail("a binary payload is truncated")
                }
                index += count
            }
            if !state.ignored && !state.opaque {
                if remainingFallback > 0, word != "u" {
                    remainingFallback -= 1
                    continue
                }
                if ["pict", "object"].contains(word) { try requireCompletePair() }
            }
            switch word {
            case "fonttbl": state.fontTable = true; state.opaque = true
            case "colortbl", "stylesheet", "pict", "object", "objdata", "listtable", "listoverridetable": state.opaque = true
            case "deff": if let parameter { defaultFont = parameter }
            case "f": state.font = parameter
            case "plain": state.font = nil
            case "fcharset":
                if state.fontTable, let font = state.font { fonts[font, default: FontEncoding()].charset = parameter }
            case "cpg", "ansicpg":
                guard let parameter, (1...65535).contains(parameter) else { throw fail("a code page is invalid") }
                if word == "cpg", state.fontTable, let font = state.font {
                    fonts[font, default: FontEncoding()].codepage = UInt32(parameter)
                } else if word == "ansicpg" { state.codepage = UInt32(parameter) }
            case "mac": state.codepage = 10000
            case "pc": state.codepage = 437
            case "pca": state.codepage = 850
            default: break
            }
            if state.ignored || state.opaque { result.append(contentsOf: bytes[start..<index]); continue }
            if word == "uc" {
                guard let count = parameter, (0...16).contains(count) else { throw fail("the fallback count is invalid") }
                state.fallbackCount = count
            } else if word == "u" {
                guard let value = parameter, (-32768...65535).contains(value) else { throw fail("an escape is outside the UTF-16 range") }
                unicodeCount += 1
                guard unicodeCount <= 1_000_000 else { throw fail("there are too many Unicode escapes") }
                let unit = UInt16(truncatingIfNeeded: value)
                if UTF16.isLeadSurrogate(unit) {
                    try requireCompletePair()
                    let placeholder = marker(UInt32(unit))
                    pending = (unit, result.count..<result.count + placeholder.count)
                    result.append(placeholder)
                } else if UTF16.isTrailSurrogate(unit) {
                    guard let high = pending else { throw fail("a low surrogate has no preceding high surrogate") }
                    let scalar = 0x10000 + (UInt32(high.unit) - 0xD800) * 0x400 + UInt32(unit) - 0xDC00
                    result.replaceSubrange(high.range, with: marker(scalar))
                    pending = nil
                } else {
                    try requireCompletePair()
                    result.append(marker(UInt32(unit)))
                }
                remainingFallback = state.fallbackCount
                continue
            } else if ["par", "line", "tab", "emdash", "endash", "bullet", "lquote", "rquote", "ldblquote", "rdblquote", "bin", "pict", "object", "field"].contains(word) {
                try requireCompletePair()
            }
            result.append(contentsOf: bytes[start..<index])
        }
        try flush()
        try requireCompletePair()
        guard groupStates.isEmpty else { throw fail("an RTF group is not closed") }
        guard result.count <= RichTextLimits.maximumSourceSize else { throw fail("the normalized input exceeds the size limit") }
        return Self(data: result, prefix: prefix)
    }

    func restoringUnicode(in html: String) throws -> String {
        let expression = try NSRegularExpression(pattern: prefix + "([0-9a-f]{1,6})END")
        let text = html as NSString
        let matches = expression.matches(in: html, range: NSRange(location: 0, length: text.length))
        var result = ""
        var cursor = 0
        for match in matches {
            try ConversionExecution.check()
            result += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let hex = text.substring(with: match.range(at: 1))
            guard let scalar = UInt32(hex, radix: 16), UnicodeScalar(scalar) != nil else {
                throw Failure(reason: "RTF Unicode: an internal character marker is invalid")
            }
            result += "&#\(scalar);"
            cursor = NSMaxRange(match.range)
        }
        result += text.substring(from: cursor)
        return result
    }
}

enum RTFCodepage {
    static func fromCharset(_ charset: Int) -> UInt32? {
        [128: 932, 129: 949, 130: 1361, 134: 936, 136: 950, 161: 1253,
         162: 1254, 163: 1258, 177: 1255, 178: 1256, 186: 1257, 204: 1251, 222: 874, 238: 1250][charset]
    }
}
