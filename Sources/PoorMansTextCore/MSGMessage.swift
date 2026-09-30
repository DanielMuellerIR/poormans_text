import Foundation
import CoreFoundation

/// MSG-Formatsemantik endet hier. Körperdarstellung und sichere Ablage übernimmt
/// dieselbe Mail-Engine wie für MIME, ohne Outlook oder Nachbardateien zu öffnen.
struct MSGMessage {
    enum Body { case text(String), html(String), rtf(Data) }
    let headers: [MIMEMessage.Header]
    let body: Body
    let attachments: [MailContent.Attachment]
    let created: Date?

    static func read(_ data: Data) throws -> MSGMessage {
        guard data.count <= MIMEMessage.maximumSourceBytes else { throw fail("the MSG exceeds the source size limit") }
        let tree = try OLECompoundDocument(data: data).storageTree()
        // Auch ungenutzte Properties dürfen keine kaputten Sektorketten verbergen.
        var streamBytes = 0
        for path in tree.streamPaths {
            try ConversionExecution.check()
            streamBytes += try tree.stream(at: path)?.count ?? 0
            guard streamBytes <= MIMEMessage.maximumSourceBytes * 2 else {
                throw fail("the MSG stream byte budget was exceeded")
            }
        }
        let root = try properties(tree, storage: [], kind: .root)
        let encoding = try codepage(root.integer(0x3FFD) ?? root.integer(0x3FDE) ?? 1252)
        func string(_ id: UInt16) throws -> String? { try stringValue(id, properties: root, tree: tree, storage: [], encoding: encoding) }
        guard let messageClass = try string(0x001A), messageClass.uppercased().hasPrefix("IPM.NOTE"),
              !messageClass.uppercased().contains("SMIME") else {
            throw fail("the MSG is not a supported unencrypted mail message")
        }
        var headers = [MIMEMessage.Header]()
        if let transport = try string(0x007D), !transport.isEmpty {
            headers = try MIMEMessage.splitHeaders(Data((transport.trimmingCharacters(in: .newlines) + "\r\n\r\n").utf8)).0
        }
        func add(_ name: String, _ value: String?) {
            if let value, !value.isEmpty, !headers.contains(where: { $0.name == name }) {
                headers.append(.init(name: name, value: value))
            }
        }
        add("subject", try string(0x0037))
        let address = try string(0x5D01) ?? string(0x0C1F)
        let sender = try string(0x0C1A)
        add("from", sender.flatMap { name in address.map { name + " <" + $0 + ">" } } ?? address ?? sender)
        add("message-id", try string(0x1035))
        var recipients = [UInt32: [String]]()
        let children = tree.storageNames(in: [])
        let recipientStores = children.filter { $0.lowercased().hasPrefix("__recip_version1.0_#") }
        guard recipientStores.count <= 2048, root.recipientCount == recipientStores.count else {
            throw fail("the MSG recipient count is invalid")
        }
        for name in recipientStores {
            try ConversionExecution.check()
            let store = [name]
            let props = try properties(tree, storage: store, kind: .object)
            let display = try stringValue(0x3001, properties: props, tree: tree, storage: store, encoding: encoding)
            let email = try stringValue(0x39FE, properties: props, tree: tree, storage: store, encoding: encoding)
                ?? stringValue(0x3003, properties: props, tree: tree, storage: store, encoding: encoding)
            if let value = display.flatMap({ name in email.map { name + " <" + $0 + ">" } }) ?? email ?? display {
                guard let type = props.integer(0x0C15), (1...3).contains(type) else { throw fail("the MSG recipient type is invalid") }
                recipients[type, default: []].append(value)
            }
        }
        add("to", try recipients[1]?.joined(separator: "; ") ?? string(0x0E04))
        add("cc", try recipients[2]?.joined(separator: "; ") ?? string(0x0E03))
        add("bcc", try recipients[3]?.joined(separator: "; ") ?? string(0x0E02))
        let date = root.fileTime(0x0039) ?? root.fileTime(0x0E06)
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
            add("date", formatter.string(from: date))
        }
        guard headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= MIMEMessage.maximumHeaderBytes else {
            throw fail("the MSG headers exceed the size limit")
        }
        let body: Body
        let nativeBody = root.integer(0x1016) ?? 0
        guard nativeBody <= 3 else { throw fail("the MSG native body type is unsupported") }
        func rtfBody(_ compressed: Data) throws -> Body {
            let rtf = try MSGCompressedRTF.decode(compressed)
            let prepared = try MSGRTFHTML.prepare(rtf)
            return prepared.html.map(Body.html) ?? .rtf(prepared.rtf)
        }
        let compressed = try root.stream(0x10090102, in: tree, storage: [])
        let htmlBytes = try root.stream(0x10130102, in: tree, storage: [])
        if nativeBody == 1, let text = try string(0x1000) {
            body = .text(text)
        } else if nativeBody == 2, let compressed, !compressed.isEmpty {
            body = try rtfBody(compressed)
        } else if let htmlBytes, !htmlBytes.isEmpty {
            let htmlEncoding = try codepage(root.integer(0x3FDE) ?? 65001)
            guard let html = String(data: htmlBytes, encoding: htmlEncoding), !html.contains("\0") else {
                throw fail("the MSG HTML body encoding is invalid")
            }
            body = .html(html)
        } else if let compressed, !compressed.isEmpty { body = try rtfBody(compressed) }
        else if let text = try string(0x1000) { body = .text(text) }
        else { throw fail("the MSG has no readable body") }
        let attachmentStores = children.filter { $0.lowercased().hasPrefix("__attach_version1.0_#") }
        guard attachmentStores.count <= MIMEMessage.maximumParts, root.attachmentCount == attachmentStores.count else {
            throw fail("the MSG attachment count is invalid")
        }
        var attachments = [MailContent.Attachment]()
        var totalBytes = 0
        for name in attachmentStores {
            try ConversionExecution.check()
            let store = [name]
            let props = try properties(tree, storage: store, kind: .object)
            func attachmentString(_ id: UInt16) throws -> String? {
                try stringValue(id, properties: props, tree: tree, storage: store, encoding: encoding)
            }
            var filename = try attachmentString(0x3707) ?? attachmentString(0x3704) ?? attachmentString(0x3001) ?? "Attachment"
            let bytes: Data
            let mediaType: String
            switch props.integer(0x3705) {
            case 1:
                guard let value = try props.stream(0x37010102, in: tree, storage: store) else {
                    throw fail("the MSG attachment data is missing")
                }
                bytes = value
                mediaType = try attachmentString(0x370E) ?? "application/octet-stream"
            case 5:
                guard props.tags.contains(0x3701000D) else { throw fail("the embedded MSG property is missing") }
                bytes = try MSGEmbeddedWriter.export(tree, storage: store + ["__substg1.0_3701000D"])
                mediaType = "application/vnd.ms-outlook"
                if !filename.lowercased().hasSuffix(".msg") { filename += ".msg" }
            default: throw fail("the MSG attachment method is unsupported; external attachment references are never opened")
            }
            totalBytes += bytes.count
            guard totalBytes <= MIMEMessage.maximumSourceBytes * 2 else { throw fail("the expanded MSG attachment budget was exceeded") }
            let cid = try attachmentString(0x3712).map { value in
                value.hasPrefix("<") && value.hasSuffix(">") ? String(value.dropFirst().dropLast()) : value
            }
            attachments.append(.init(name: filename, mediaType: mediaType, data: bytes,
                                     contentID: cid, contentLocation: try attachmentString(0x3713)))
        }
        return .init(headers: headers, body: body, attachments: attachments, created: date)
    }

    static func properties(_ tree: OLECompoundDocument.StorageTree, storage: [String], kind: MSGProperties.ObjectKind) throws -> MSGProperties {
        guard let data = try tree.stream(at: storage + ["__properties_version1.0"]) else {
            throw fail("the MSG property stream is missing")
        }
        return try MSGProperties(data: data, kind: kind)
    }

    static func stringValue(_ id: UInt16, properties: MSGProperties, tree: OLECompoundDocument.StorageTree,
                            storage: [String], encoding: String.Encoding) throws -> String? {
        for type: UInt32 in [0x001F, 0x001E] {
            let tag = UInt32(id) << 16 | type
            if let data = try properties.stream(tag, in: tree, storage: storage) {
                return try properties.decodedString(data, for: tag, ansiEncoding: encoding)
            }
        }
        return nil
    }

    static func codepage(_ value: UInt32) throws -> String.Encoding {
        let cf = CFStringConvertWindowsCodepageToEncoding(value)
        guard cf != kCFStringEncodingInvalidId else { throw fail("the MSG code page is unsupported") }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static func fail(_ reason: String) -> MSGProperties.Failure { .init(reason: reason) }
}
