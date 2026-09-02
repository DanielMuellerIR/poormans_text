import Foundation

/// Liest ein Safari-Webarchiv: eine Property-List mit der Hauptressource
/// (HTML samt Adresse und Zeichensatz) und den Nebenressourcen (Bilder,
/// Stylesheets, Skripte). Nur Bilder werden weiterverwendet.
enum WebArchiveReader {
    struct Archive {
        let html: String
        let baseURL: URL?
        let subresources: [String: HTMLImageSourceResolver.Subresource]
        let assumedEncoding: Bool
    }

    static let maximumSourceBytes = 256 * 1_024 * 1_024

    /// Binäre Plists beginnen mit `bplist00`; die XML-Form mit `<?xml`.
    static func looksLikeWebArchive(prefix: Data) -> Bool {
        if prefix.starts(with: Array("bplist00".utf8)) {
            return true
        }
        let head = String(decoding: prefix.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<?xml") && head.contains("plist")
    }

    static func read(_ data: Data) throws -> Archive {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw WebArchiveError("the web archive is not a readable property list")
        }
        guard let root = plist as? [String: Any],
              let main = root["WebMainResource"] as? [String: Any],
              let mainData = main["WebResourceData"] as? Data else {
            throw WebArchiveError("the web archive has no main resource")
        }
        let mimeType = (main["WebResourceMIMEType"] as? String ?? "").lowercased()
        guard mimeType.contains("html") || mimeType.contains("xml") else {
            throw WebArchiveError("the web archive's main resource is not HTML (\(mimeType))")
        }

        var assumedEncoding = false
        let html: String
        if let encodingName = main["WebResourceTextEncodingName"] as? String,
           let encoding = String.Encoding(ianaCharSetName: encodingName),
           let text = String(data: mainData, encoding: encoding) {
            html = text
        } else if let text = String(data: mainData, encoding: .utf8) {
            html = text
        } else if let text = String(data: mainData, encoding: .windowsCP1252) {
            html = text
            assumedEncoding = true
        } else {
            throw WebArchiveError("the web archive's HTML could not be decoded")
        }

        var subresources = [String: HTMLImageSourceResolver.Subresource]()
        for case let resource as [String: Any] in root["WebSubresources"] as? [Any] ?? [] {
            guard let url = resource["WebResourceURL"] as? String,
                  let resourceData = resource["WebResourceData"] as? Data,
                  let resourceMIME = resource["WebResourceMIMEType"] as? String,
                  resourceMIME.lowercased().hasPrefix("image/") else {
                continue
            }
            subresources[url] = HTMLImageSourceResolver.Subresource(data: resourceData, mimeType: resourceMIME)
        }

        return Archive(
            html: html,
            baseURL: (main["WebResourceURL"] as? String).flatMap(URL.init(string:)),
            subresources: subresources,
            assumedEncoding: assumedEncoding
        )
    }

    struct WebArchiveError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

extension String.Encoding {
    /// IANA-Namen wie `utf-8` oder `iso-8859-1` in Foundation-Kodierungen.
    init?(ianaCharSetName name: String) {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }
        self.init(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
