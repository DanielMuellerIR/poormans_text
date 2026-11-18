enum RTFDAttachmentGroups {
    struct Attachment {
        let destination: Range<Int>
        let range: Range<Int>
        let name: Range<Int>
        let codepage: UInt32
    }

    private struct Group {
        let start: Int
        var firstControl = true
        var starred = false
        var opaque = false
        var codepage: UInt32 = 1252
        var attachmentStart: Int?
    }

    static func scan(
        _ bytes: [UInt8],
        rejectInlineObjects: Bool,
        failure: (String) -> ConversionError
    ) throws -> [Attachment] {
        var groups = [Group]()
        var attachments = [Attachment]()
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
                    let destination = group.start..<(index + 1)
                    let name = nameStart..<index
                    var range = destination
                    // Cocoa umschließt die Bilddestination und ihr Platzhalterbyte mit
                    // einer eigenen Gruppe. Das Byte gehört zum Bild, nicht zum Text.
                    if groups.count > 1, let outer = groups.last, outer.start + 1 == group.start,
                       index + 2 < bytes.count, bytes[index + 1] == 0xAC, bytes[index + 2] == 125 {
                        groups.removeLast()
                        range = outer.start..<(index + 3)
                        index += 2
                    }
                    guard attachments.count < RichTextLimits.maximumPackageEntries else {
                        throw failure("RTFD attachment count exceeds its limit")
                    }
                    attachments.append(Attachment(destination: destination, range: range, name: name, codepage: group.codepage))
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
            if rejectInlineObjects, ["pict", "object", "objdata", "shppict", "nonshppict"].contains(word),
               !groups[current].opaque {
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
        return attachments
    }
}
