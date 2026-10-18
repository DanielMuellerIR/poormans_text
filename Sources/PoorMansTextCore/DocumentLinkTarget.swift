import Foundation

enum DocumentLinkTarget {
    static func external(_ raw: String) -> String? {
        guard raw.utf8.count <= 8_192, !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !raw.contains("\\"), let url = URLComponents(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "mailto" { guard !url.path.isEmpty else { return nil } }
        else { guard url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil } }
        return raw
    }
}
