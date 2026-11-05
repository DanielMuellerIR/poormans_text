import Foundation

/// Swift-Strings vergleichen Unicode-kanonisch; Linux-Dateinamen dagegen als Bytes.
enum FileSystemPath {
    static func key(_ path: String) -> String {
        #if os(Linux)
        let hex = Array("0123456789ABCDEF".utf8)
        var result = [UInt8]()
        result.reserveCapacity(path.utf8.count)
        for byte in path.utf8 {
            if byte < 128 && byte != 37 { result.append(byte) }
            else { result.append(contentsOf: [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]]) }
        }
        // Slash bleibt erhalten, damit Schlüssel weiterhin echte Pfadgrenzen besitzen.
        return String(decoding: result, as: UTF8.self)
        #else
        return path
        #endif
    }

    static func equal(_ left: String, _ right: String) -> Bool {
        #if os(Linux)
        return left.utf8.elementsEqual(right.utf8)
        #else
        return left == right
        #endif
    }

    static func equal(_ left: URL, _ right: URL) -> Bool {
        #if os(Linux)
        return equal(left.path, right.path)
        #else
        return left == right
        #endif
    }

    static func hasPrefix(_ path: String, _ prefix: String) -> Bool {
        #if os(Linux)
        return path.utf8.starts(with: prefix.utf8)
        #else
        return path.hasPrefix(prefix)
        #endif
    }
}
