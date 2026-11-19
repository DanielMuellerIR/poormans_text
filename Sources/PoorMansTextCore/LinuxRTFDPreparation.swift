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
        var replacements = [(range: Range<Int>, marker: String, name: String)]()
        var verifiedNames = Set<String>()
        var viewerLimitedFormats = Set<String>()
        for attachment in try RTFDAttachmentGroups.scan(bytes, rejectInlineObjects: true, failure: failure) {
            try ConversionExecution.check()
            let name = try attachmentName(Array(bytes[attachment.name]), codepage: attachment.codepage, failure: failure)
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
            let marker = prefix + String(replacements.count) + "END"
            replacements.append((attachment.range, marker, name))
        }
        var prepared = Data()
        var cursor = 0
        for replacement in replacements {
            prepared.append(contentsOf: bytes[cursor..<replacement.range.lowerBound])
            // Die Gruppe beendet ein direkt davor stehendes RTF-Steuerwort.
            prepared.append(contentsOf: "{\(replacement.marker)}".utf8)
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
        var controlsStarted = false
        while index < bytes.count {
            if bytes[index] == 92 {
                index += 1
                guard index < bytes.count else { throw failure("RTFD attachment name is truncated") }
                if [92, 123, 125].contains(bytes[index]), !controlsStarted { name.append(bytes[index]); index += 1; continue }
                if bytes[index] == 39, !controlsStarted {
                    guard index + 2 < bytes.count,
                          let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else {
                        throw failure("RTFD attachment name has an invalid byte escape")
                    }
                    name.append(value); index += 3; continue
                }
                let start = index
                while index < bytes.count, (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                guard ["width", "height", "appleattachmentpadding", "appleembedtype", "appleaqc"].contains(word) else {
                    throw failure("unsupported RTFD attachment-name control: \(word)")
                }
                controlsStarted = true
                if word == "appleaqc" { continue }
                let parameterStart = index
                if index < bytes.count, bytes[index] == 45 { index += 1 }
                let numberStart = index
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > numberStart else { throw failure("RTFD attachment parameter is malformed: \(word)") }
                if word == "appleembedtype", !bytes[parameterStart..<index].elementsEqual([48]) {
                    throw failure("RTFD supports only static image attachments")
                }
            } else if controlsStarted {
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
