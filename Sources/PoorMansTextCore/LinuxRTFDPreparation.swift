#if os(Linux)
import Foundation
import CoreFoundation
import Glibc

/// Ersetzt nur RTFD-Bilddestinationen in der privaten Kopie. Der übrige RTF-
/// Bytestrom bleibt für den bestehenden Unicode-/Listenpfad unverändert.
struct LinuxRTFDPreparation {
    let data: Data
    let representedNames: Set<String>
    let viewerLimitedFormats: Set<String>
    private let prefix: String
    private let images: [(marker: String, name: String)]

    private struct Group {
        let start: Int
        var firstControl = true
        var starred = false
        var opaque = false
        var codepage: UInt32 = 1252
        var attachmentStart: Int?
    }

    static func prepare(package: URL) throws -> Self {
        func failure(_ reason: String) -> ConversionError { .invalidRichText(package, reason: reason) }
        let directory = open(package.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw failure("the private RTFD package could not be opened") }
        defer { close(directory) }
        func member(_ name: String) throws -> Data {
            try VerifiedFile.openMember(named: name, in: directory,
                sourceURL: package.appendingPathComponent(name),
                failure: { _ in failure("RTFD member could not be read: \(name)") }) { source in
                guard source.isRegularFile, source.info.st_size >= 0,
                      source.info.st_size <= RichTextLimits.maximumSourceSize else {
                    throw failure("RTFD member is not a bounded regular file: \(name)")
                }
                var data = Data()
                _ = try source.readChunks(maximumBytes: RichTextLimits.maximumSourceSize,
                    chunkSize: 262_144, budgetExceeded: { failure("RTFD member exceeds its size limit") }) {
                    data.append(contentsOf: $0); return true
                }
                return data
            }
        }
        let source = try member("TXT.rtf")
        let bytes = [UInt8](source)
        var prefix: String
        repeat { prefix = "POORMANSTEXTRTFDIMAGE" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        while source.range(of: Data(prefix.utf8)) != nil
        var groups = [Group]()
        var replacements = [(range: Range<Int>, marker: String, name: String)]()
        var verifiedNames = Set<String>()
        var viewerLimitedFormats = Set<String>()
        var index = 0
        var nextCancellationCheck = 0
        let opaqueDestinations: Set<String> = ["pict", "object", "objdata", "fonttbl", "colortbl", "stylesheet", "info", "listtable", "listoverridetable"]
        func alpha(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
        func digit(_ b: UInt8) -> Bool { (48...57).contains(b) }
        while index < bytes.count {
            if index >= nextCancellationCheck { try ConversionExecution.check(); nextCancellationCheck = index + 4096 }
            let byte = bytes[index]
            if byte == 123 {
                guard groups.count < 256 else { throw failure("RTFD group nesting exceeds its limit") }
                if groups.last?.attachmentStart != nil { throw failure("nested RTFD attachment names are unsupported") }
                groups.append(Group(start: index, opaque: groups.last?.opaque ?? false, codepage: groups.last?.codepage ?? 1252))
                index += 1; continue
            }
            if byte == 125 {
                guard let group = groups.popLast() else { throw failure("RTFD has an unmatched closing group") }
                if let nameStart = group.attachmentStart {
                    let name = try attachmentName(Array(bytes[nameStart..<index]), codepage: group.codepage, failure: failure)
                    let formats = ["png": "png", "jpg": "jpg", "jpeg": "jpg", "tif": "tiff",
                                   "tiff": "tiff", "gif": "gif", "bmp": "bmp", "webp": "webp", "heic": "heic"]
                    guard let expectedFormat = formats[URL(fileURLWithPath: name).pathExtension.lowercased()] else {
                        throw failure("RTFD supports only local static PNG, JPEG, TIFF, GIF, BMP, WebP and HEIC attachments")
                    }
                    if verifiedNames.insert(FileSystemPath.key(name)).inserted {
                        let image = try member(name)
                        let info: RasterImageInfo
                        do { info = try RasterImageBackend.validate(image) }
                        catch let error as RasterImageValidationError {
                            throw failure("RTFD attachment \(name): \(error.localizedDescription)")
                        } catch let ConversionError.invalidInput(_, _, reason) {
                            throw failure("RTFD attachment \(name): \(reason)")
                        }
                        guard info.fileExtension == expectedFormat, info.frameCount == 1 else {
                            throw failure("RTFD attachment \(name) must be a single static image matching its file extension")
                        }
                        if ["tiff", "heic"].contains(info.fileExtension) {
                            viewerLimitedFormats.insert(info.fileExtension)
                        }
                    }
                    guard replacements.count < RichTextLimits.maximumPackageEntries else { throw failure("RTFD attachment count exceeds its limit") }
                    let marker = prefix + String(replacements.count) + "END"
                    replacements.append((group.start..<(index + 1), marker, name))
                }
                index += 1; continue
            }
            guard byte == 92, index + 1 < bytes.count else {
                if ![9, 10, 13, 32].contains(byte), !groups.isEmpty { groups[groups.count - 1].firstControl = false }
                index += 1; continue
            }
            let start = index
            index += 1
            guard alpha(bytes[index]) else {
                if bytes[index] == 42, !groups.isEmpty, groups[groups.count - 1].firstControl {
                    groups[groups.count - 1].starred = true
                } else if bytes[index] == 39 {
                    guard index + 2 < bytes.count else { throw failure("RTFD contains a truncated byte escape") }
                    index += 2
                }
                index += 1; continue
            }
            let wordStart = index
            while index < bytes.count, alpha(bytes[index]) { index += 1 }
            let word = String(decoding: bytes[wordStart..<index], as: UTF8.self)
            let numberStart = index
            if index < bytes.count, bytes[index] == 45 { index += 1 }
            while index < bytes.count, digit(bytes[index]) { index += 1 }
            let parameter = Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))
            if index < bytes.count, bytes[index] == 32 { index += 1 }
            if word == "bin" {
                guard let parameter, parameter >= 0, parameter <= bytes.count - index else { throw failure("RTFD binary data is truncated") }
                index += parameter
            }
            guard !groups.isEmpty else { throw failure("RTFD control word is outside its document group") }
            let current = groups.count - 1
            if ["pict", "object", "objdata", "shppict", "nonshppict"].contains(word), !groups[current].opaque {
                throw failure("inline RTF pictures and objects in RTFD are not supported; local static raster package attachments are required")
            }
            if word == "NeXTGraphic", !groups[current].opaque {
                guard groups[current].firstControl else { throw failure("RTFD attachment is not a separate destination") }
                groups[current].attachmentStart = index
            } else if groups[current].firstControl,
                      groups[current].starred || opaqueDestinations.contains(word) {
                groups[current].opaque = true
            }
            if word == "ansicpg", let parameter, parameter > 0, parameter <= Int(UInt32.max) { groups[current].codepage = UInt32(parameter) }
            if word == "mac" { groups[current].codepage = 10000 }
            groups[current].firstControl = false
            guard index > start else { throw failure("RTFD parser did not advance") }
        }
        guard groups.isEmpty else { throw failure("RTFD has an unclosed group") }
        var prepared = Data()
        var cursor = 0
        for replacement in replacements {
            prepared.append(contentsOf: bytes[cursor..<replacement.range.lowerBound])
            prepared.append(contentsOf: replacement.marker.utf8)
            cursor = replacement.range.upperBound
        }
        prepared.append(contentsOf: bytes[cursor..<bytes.count])
        guard prepared.count <= RichTextLimits.maximumSourceSize else { throw failure("prepared RTFD exceeds its size limit") }
        return Self(data: prepared, representedNames: verifiedNames, viewerLimitedFormats: viewerLimitedFormats, prefix: prefix,
                    images: replacements.map { ($0.marker, $0.name) })
    }

    func restoringImages(in html: String, packageName: String, inputURL: URL) throws -> String {
        guard try HTMLImageAttributes.imageTags(in: html).isEmpty else {
            throw ConversionError.invalidRichText(inputURL, reason: "the RTF reader produced an unsupported inline image outside validated RTFD package attachments")
        }
        let expression = try NSRegularExpression(pattern: prefix + "([0-9]+)END")
        let source = html as NSString
        let matches = expression.matches(in: html, range: NSRange(location: 0, length: source.length))
        var seen = Set<Int>()
        var result = ""
        var cursor = 0
        for match in matches {
            try ConversionExecution.check()
            guard let index = Int(source.substring(with: match.range(at: 1))), images.indices.contains(index),
                  seen.insert(index).inserted else {
                throw ConversionError.fileSystemFailure("an internal RTFD attachment marker is invalid")
            }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let path = MarkdownLinkTargetRewriter.percentEncodedPath(packageName + "/" + images[index].name)
            result += "<img src=\"\(path)\" alt=\"image\">"
            cursor = NSMaxRange(match.range)
        }
        guard seen.count == images.count else {
            throw ConversionError.fileSystemFailure("an RTFD attachment position was lost during conversion")
        }
        result += source.substring(from: cursor)
        return result
    }

    static func normalizingLiteralLists(in html: String) throws -> String {
        let paragraphs = try NSRegularExpression(pattern: #"<p(?:\s[^>]*)?>(.*?)</p>"#, options: [.dotMatchesLineSeparators])
        let item = try NSRegularExpression(pattern: #"^(\s*(?:(?:<(?:span|strong|em|b|i|u)(?:\s[^>]*)?>)\s*)*)(?:&#(?:x2022|8226);|•|-)(?:[ \t]|\u00a0|&nbsp;|&#160;)+(.+)$"#, options: [.dotMatchesLineSeparators])
        let source = html as NSString
        var output = ""
        var end = 0
        var listOpen = false
        for paragraph in paragraphs.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let gap = source.substring(with: NSRange(location: end, length: paragraph.range.location - end))
            let content = source.substring(with: paragraph.range(at: 1)) as NSString
            let match = item.firstMatch(in: content as String, range: NSRange(location: 0, length: content.length))
            if listOpen && (match == nil || !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                output += "</ul>"; listOpen = false
            }
            output += gap
            if let match {
                if !listOpen { output += "<ul>"; listOpen = true }
                output += "<li>" + content.substring(with: match.range(at: 1)) + content.substring(with: match.range(at: 2)) + "</li>"
            } else {
                output += source.substring(with: paragraph.range)
            }
            end = paragraph.range.location + paragraph.range.length
        }
        if listOpen { output += "</ul>" }
        output += source.substring(from: end)
        return output
    }

    private static func attachmentName(_ bytes: [UInt8], codepage: UInt32,
                                        failure: (String) -> ConversionError) throws -> String {
        var name = [UInt8]()
        var index = 0
        var dimensionsStarted = false
        while index < bytes.count {
            if bytes[index] == 92 {
                index += 1
                guard index < bytes.count else { throw failure("RTFD attachment name is truncated") }
                if [92, 123, 125].contains(bytes[index]), !dimensionsStarted { name.append(bytes[index]); index += 1; continue }
                if bytes[index] == 39, !dimensionsStarted {
                    guard index + 2 < bytes.count,
                          let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else {
                        throw failure("RTFD attachment name has an invalid byte escape")
                    }
                    name.append(value); index += 3; continue
                }
                let start = index
                while index < bytes.count, (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                guard ["width", "height"].contains(word) else { throw failure("unsupported RTFD attachment-name control: \(word)") }
                dimensionsStarted = true
                if index < bytes.count, bytes[index] == 45 { index += 1 }
                let numberStart = index
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > numberStart else { throw failure("RTFD attachment dimensions are malformed") }
            } else if dimensionsStarted {
                guard [9, 10, 13, 32].contains(bytes[index]) else { throw failure("RTFD attachment contains unexpected content") }
                index += 1
            } else {
                name.append(bytes[index]); index += 1
            }
            guard name.count <= 4096 else { throw failure("RTFD attachment name exceeds its limit") }
        }
        let encoding = CFStringConvertWindowsCodepageToEncoding(codepage)
        let decoded = String(bytes: name, encoding: .utf8)
            ?? (encoding == kCFStringEncodingInvalidId ? nil : String(data: Data(name), encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))))
        guard let decoded else { throw failure("RTFD attachment name cannot be decoded") }
        let result = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result != ".", result != "..", result != "TXT.rtf",
              !result.contains("/"), !result.contains("\\"), !result.contains(":"),
              !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw failure("RTFD attachment must name one local package file")
        }
        return result
    }
}
#endif
