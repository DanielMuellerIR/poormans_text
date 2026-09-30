import Foundation

/// Trennt den darstellbaren Körper von Anhängen, ohne Fremdpfade anzufassen.
enum MailContent {
    struct Body {
        let text: String
        let isHTML: Bool
    }

    struct Attachment {
        let name: String
        let mediaType: String
        let data: Data
        let contentID: String?
        let contentLocation: String?
    }

    struct Selection {
        var bodies = [Body]()
        var attachments = [Attachment]()
        var warnings = [ConversionWarning]()
    }

    struct SavedAttachment {
        let displayName: String
        let relativePath: String
    }

    static func stageAttachments(_ attachments: [Attachment], in output: URL) throws -> [SavedAttachment] {
        guard !attachments.isEmpty else { return [] }
        let directory = output.appendingPathComponent("attachments", isDirectory: true)
        // Nur einen neuen Ordner verwenden. Ein vorhandener Ordner oder Symlink ist kein eigenes Ziel.
        guard mkdir(directory.path, 0o700) == 0 else {
            throw ConversionError.fileSystemFailure("the mail attachment directory could not be created exclusively")
        }
        var saved = [SavedAttachment]()
        for (index, attachment) in attachments.enumerated() {
            try ConversionExecution.check()
            let name = storedName(attachment.name, index: index + 1)
            do {
                try attachment.data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
            } catch {
                throw ConversionError.fileSystemFailure(error.localizedDescription)
            }
            let displayName = attachment.name.components(separatedBy: .controlCharacters).joined(separator: " ")
            saved.append(SavedAttachment(displayName: displayName, relativePath: "attachments/" + name))
        }
        return saved
    }

    static func subresources(_ attachments: [Attachment]) throws -> [String: HTMLImageSourceResolver.Subresource] {
        var result = [String: HTMLImageSourceResolver.Subresource]()
        for attachment in attachments {
            try ConversionExecution.check()
            let keys = [attachment.contentID.map { "cid:" + $0 }, attachment.contentLocation].compactMap { $0 }
            for key in Set(keys) {
                guard !key.isEmpty, result[key] == nil else {
                    throw MIMEMessage.Failure(reason: "the mail has duplicate or empty resource identifiers")
                }
                result[key] = HTMLImageSourceResolver.Subresource(data: attachment.data, mimeType: attachment.mediaType)
            }
        }
        return result
    }

    static func select(_ part: MIMEMessage.Part) throws -> Selection {
        try ConversionExecution.check()
        let attached = part.disposition == "attachment" || part.filename != nil
        if attached || (part.children.isEmpty && !["text/plain", "text/html"].contains(part.mediaType)) {
            return try attachment(part)
        }
        if part.children.isEmpty {
            return Selection(bodies: [Body(text: try part.text(), isHTML: part.mediaType == "text/html")])
        }
        if part.mediaType == "multipart/encrypted" {
            throw MIMEMessage.Failure(reason: "encrypted mail cannot be converted without decryption")
        }
        let children = try part.children.map { child -> Selection in
            do { return try select(child) }
            catch let error as MIMEMessage.Failure where part.mediaType == "multipart/alternative" {
                return Selection(warnings: [ConversionWarning(code: "mail.alternativeUnreadable",
                    message: "A mail body alternative could not be rendered: \(error.reason)")])
            }
        }
        if part.mediaType == "multipart/alternative" {
            // MIME ordnet Alternativen nach steigender Treue; nur eine Körperdarstellung ausgeben.
            guard var chosen = children.last(where: { !$0.bodies.isEmpty }) else {
                throw MIMEMessage.Failure(reason: "the mail has no supported body alternative")
            }
            for child in children where child.bodies.isEmpty {
                chosen.attachments += child.attachments
                chosen.warnings += child.warnings
            }
            return chosen
        }
        var result = Selection()
        if part.mediaType == "multipart/related" {
            let start = part.parameters["start"].map(contentID)
            let rootIndex: Int
            if let start {
                guard let index = part.children.firstIndex(where: { $0.header("content-id").map(contentID) == start }) else {
                    throw MIMEMessage.Failure(reason: "the related mail root is missing")
                }
                rootIndex = index
            } else { rootIndex = 0 }
            for (index, child) in children.enumerated() {
                if index == rootIndex { result.bodies += child.bodies }
                else if !child.bodies.isEmpty {
                    // Ein verwandter Textteil ist eine Ressource, kein zweiter Nachrichtenkörper.
                    let resource = try attachment(part.children[index])
                    result.attachments += resource.attachments
                    result.warnings += resource.warnings
                }
                result.attachments += child.attachments
                result.warnings += child.warnings
            }
            return result
        }
        for child in children {
            result.bodies += child.bodies
            result.attachments += child.attachments
            result.warnings += child.warnings
        }
        return result
    }

    private static func attachment(_ part: MIMEMessage.Part) throws -> Selection {
        let name = try MIMEMessage.decodedHeader(part.filename ?? defaultName(for: part.mediaType))
        // Ein angehängter Multipart-Container braucht seine MIME-Kopfzeilen zum erneuten Lesen.
        let data = part.children.isEmpty ? part.body : part.sourceData
        let attachment = Attachment(name: name, mediaType: part.mediaType, data: data,
                                    contentID: part.header("content-id").map(contentID),
                                    contentLocation: part.header("content-location"))
        var result = Selection(attachments: [attachment])
        if part.filename == nil, part.disposition != "attachment", !part.mediaType.hasPrefix("image/") {
            result.warnings.append(ConversionWarning(code: "mail.partSavedAsAttachment",
                message: "A mail part of type \(part.mediaType) was saved as an attachment instead of being rendered."))
        }
        return result
    }

    private static func defaultName(for mediaType: String) -> String {
        if mediaType.hasPrefix("multipart/") { return "attachment.mime" }
        switch mediaType {
        case "message/rfc822": return "message.eml"
        case "text/plain": return "text.txt"
        case "text/html": return "document.html"
        case "image/png": return "image.png"
        case "image/jpeg": return "image.jpg"
        case "image/gif": return "image.gif"
        default: return "attachment.bin"
        }
    }

    static func contentID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// Ein Präfix verhindert Kollisionen auch auf Dateisystemen ohne Groß-/Kleinschreibung.
    /// Nur eigene ASCII-Zeichen bilden den Pfad; Anzeigenamen bleiben davon getrennt.
    static func storedName(_ name: String, index: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.".utf8)
        let bytes = name.utf8.prefix(120).map { allowed.contains($0) ? $0 : UInt8(95) }
        let suffix = String(decoding: bytes, as: UTF8.self)
        return "\(index)-" + (suffix.isEmpty ? "attachment.bin" : suffix)
    }
}
