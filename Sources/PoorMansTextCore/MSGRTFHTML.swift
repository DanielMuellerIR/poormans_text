import Foundation
import CoreFoundation

/// Liest MS-OXRTFEX-HTML und normalisiert Unicode für den normalen RTF-Importer.
enum MSGRTFHTML {
    private struct State {
        var skip = false
        var inheritedSkip = false
        var suppressed = false
        var fontTable = false
        var font = 0
        var codepage: UInt32 = 1252
        var unicodeFallback = 1
    }

    static func decode(_ data: Data) throws -> String? { try prepare(data).html }

    static func prepare(_ data: Data) throws -> (html: String?, rtf: Data) {
        let bytes = Array(data)
        guard bytes.count <= MSGCompressedRTF.maximumBytes, bytes.starts(with: Array(#"{\rtf"#.utf8)) else {
            throw MSGProperties.Failure(reason: "the MSG RTF body has no RTF header")
        }
        var state = State()
        var stack = [State]()
        var fonts = [Int: UInt32]()
        var output = [UInt16]()
        var raw = Data()
        var fallback = 0
        var position = 0
        var recognized = false
        var edits = [(Range<Int>, Data)]()
        func edit(_ range: Range<Int>, replacement: Data = Data()) throws {
            guard edits.count < 1_000_000 else { throw MSGProperties.Failure(reason: "the MSG RTF has too many Unicode escapes") }
            edits.append((range, replacement))
        }
        func fail(_ reason: String) -> MSGProperties.Failure { .init(reason: reason) }
        func append(_ units: [UInt16]) throws {
            guard output.count + units.count <= MSGCompressedRTF.maximumBytes / 2 else {
                throw fail("the encapsulated MSG HTML exceeds the size limit")
            }
            output += units
        }
        func flush() throws {
            guard !raw.isEmpty else { return }
            let codepage = fonts[state.font] ?? state.codepage
            let cf = CFStringConvertWindowsCodepageToEncoding(codepage)
            guard cf != kCFStringEncodingInvalidId,
                  let text = String(data: raw, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) else {
                throw fail("the encapsulated MSG HTML code page cannot be decoded")
            }
            try append(Array(text.utf16))
            raw.removeAll(keepingCapacity: true)
        }
        func literal(_ byte: UInt8, start: Int) throws {
            if fallback > 0 { fallback -= 1; try edit(start..<position); return }
            if !state.skip && !state.suppressed { raw.append(byte) }
        }
        while position < bytes.count {
            if position % 4096 == 0 { try ConversionExecution.check() }
            let byte = bytes[position]; position += 1
            if byte == 123 {
                fallback = 0
                try flush()
                guard stack.count < 256 else { throw fail("the MSG RTF group nesting is too deep") }
                stack.append(state)
                state.inheritedSkip = state.skip
            } else if byte == 125 {
                fallback = 0
                try flush()
                guard let parent = stack.popLast() else { throw fail("the MSG RTF has an unmatched group end") }
                state = parent
            } else if byte == 92 {
                let controlStart = position - 1
                guard position < bytes.count else { throw fail("the MSG RTF control is truncated") }
                let first = bytes[position]; position += 1
                if [92, 123, 125].contains(first) { try literal(first, start: controlStart); continue }
                if first == 39 {
                    guard position + 2 <= bytes.count,
                          let value = UInt8(String(decoding: bytes[position..<position + 2], as: UTF8.self), radix: 16) else {
                        throw fail("the MSG RTF hexadecimal escape is invalid")
                    }
                    position += 2; try literal(value, start: controlStart); continue
                }
                if first == 42 { try flush(); state.skip = true; continue }
                if first == 126 { try literal(160, start: controlStart); continue }
                if first == 95 { if fallback > 0 { fallback -= 1; try edit(controlStart..<position); continue }; try flush(); if !state.skip && !state.suppressed { try append([0x2011]) }; continue }
                guard (65...90).contains(first) || (97...122).contains(first) else {
                    if fallback > 0 { fallback -= 1; try edit(controlStart..<position) }
                    continue
                }
                let start = position - 1
                while position < bytes.count, (65...90).contains(bytes[position]) || (97...122).contains(bytes[position]) { position += 1 }
                let command = String(decoding: bytes[start..<position], as: UTF8.self)
                let numberStart = position
                if position < bytes.count, bytes[position] == 45 { position += 1 }
                while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
                let parameter: Int?
                if position > numberStart {
                    guard position - numberStart <= 11,
                          let value = Int(String(decoding: bytes[numberStart..<position], as: UTF8.self)) else {
                        throw fail("the MSG RTF control parameter is invalid")
                    }
                    parameter = value
                } else { parameter = nil }
                if position < bytes.count, bytes[position] == 32 { position += 1 }
                try flush()
                if fallback > 0, command != "u" {
                    if command == "bin" {
                        guard let count = parameter, count >= 0, count <= bytes.count - position else { throw fail("the MSG RTF binary group is truncated") }
                        position += count
                    }
                    fallback -= 1
                    try edit(controlStart..<position)
                    continue
                }
                switch command {
                case "fromhtml": if stack.count == 1 && parameter == 1 { recognized = true }
                case "fonttbl": state.skip = true; state.fontTable = true
                case "colortbl", "stylesheet", "info", "pict", "object", "fldinst", "header", "footer", "listtable", "listoverridetable": state.skip = true
                case "htmltag": state.skip = state.inheritedSkip
                case "htmlrtf": state.suppressed = parameter != 0
                case "ansicpg":
                    guard let value = parameter, value > 0, value <= 65535 else { throw fail("the MSG RTF code page is invalid") }
                    state.codepage = UInt32(value)
                case "f": if let value = parameter { state.font = value }
                case "fcharset":
                    if state.fontTable, let value = parameter, let codepage = charsetCodepage(value) { fonts[state.font] = codepage }
                case "cpg":
                    if state.fontTable {
                        guard let value = parameter, value > 0, value <= 65535 else { throw fail("the MSG RTF font code page is invalid") }
                        fonts[state.font] = UInt32(value)
                    }
                case "uc":
                    guard let value = parameter, (0...16).contains(value) else { throw fail("the MSG RTF Unicode fallback count is invalid") }
                    state.unicodeFallback = value
                case "u":
                    guard let value = parameter, (-32768...65535).contains(value) else { throw fail("the MSG RTF Unicode escape is invalid") }
                    if !state.skip && !state.suppressed { try append([UInt16(truncatingIfNeeded: value)]) }
                    // Pandocs RTF-Leser verschluckt nach einem Unicode-Fallback
                    // ein weiteres Literal. Nur seine temporäre Eingabe wird
                    // auf uc0 normalisiert; die Quelle bleibt bytegleich.
                    try edit(controlStart..<position, replacement: Data("\\uc0\\u\(value) ".utf8))
                    fallback = state.unicodeFallback
                case "bin":
                    guard let count = parameter, count >= 0, count <= bytes.count - position else { throw fail("the MSG RTF binary group is truncated") }
                    position += count
                case "par", "line": if !state.skip && !state.suppressed { try append([13, 10]) }
                case "tab": if !state.skip && !state.suppressed { try append([9]) }
                case "emdash": if !state.skip && !state.suppressed { try append([0x2014]) }
                case "endash": if !state.skip && !state.suppressed { try append([0x2013]) }
                case "lquote": if !state.skip && !state.suppressed { try append([0x2018]) }
                case "rquote": if !state.skip && !state.suppressed { try append([0x2019]) }
                case "ldblquote": if !state.skip && !state.suppressed { try append([0x201C]) }
                case "rdblquote": if !state.skip && !state.suppressed { try append([0x201D]) }
                default: break
                }
            } else if byte != 13 && byte != 10 { try literal(byte, start: position - 1) }
        }
        try flush()
        guard stack.isEmpty else { throw fail("the MSG RTF group is not closed") }
        guard recognized else {
            var normalized = Data()
            var cursor = 0
            for (range, replacement) in edits {
                normalized.append(contentsOf: bytes[cursor..<range.lowerBound])
                normalized.append(replacement)
                cursor = range.upperBound
                guard normalized.count <= MSGCompressedRTF.maximumBytes else { throw fail("the normalized MSG RTF exceeds the size limit") }
            }
            normalized.append(contentsOf: bytes[cursor...])
            guard normalized.count <= MSGCompressedRTF.maximumBytes else { throw fail("the normalized MSG RTF exceeds the size limit") }
            return (nil, normalized)
        }
        var utf16 = Data()
        for unit in output { utf16.append(UInt8(truncatingIfNeeded: unit)); utf16.append(UInt8(truncatingIfNeeded: unit >> 8)) }
        guard let html = String(data: utf16, encoding: .utf16LittleEndian), !html.contains("\0") else {
            throw fail("the encapsulated MSG HTML Unicode is invalid")
        }
        return (html, data)
    }

    private static func charsetCodepage(_ charset: Int) -> UInt32? {
        [0: 1252, 128: 932, 129: 949, 130: 1361, 134: 936, 136: 950, 161: 1253,
         162: 1254, 163: 1258, 177: 1255, 178: 1256, 186: 1257, 204: 1251, 222: 874, 238: 1250][charset]
    }
}
