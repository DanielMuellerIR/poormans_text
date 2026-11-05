import Foundation

/// Der Textbeleg umfasst ausschließlich die ursprüngliche TXT.rtf, nicht die Anhänge.
enum RTFDSource {
    static func withText<T>(at url: URL, body: (VerifiedFile) throws -> T) throws -> T {
        try VerifiedFile.open(at: url, failure: { _ in ImportFailure("the RTFD source could not be opened") }) { package in
            guard package.isDirectory else { throw ImportFailure("the RTFD source is not a directory package") }
            return try VerifiedFile.openMember(named: "TXT.rtf", in: package.descriptor,
                sourceURL: url.appendingPathComponent("TXT.rtf"),
                failure: { _ in ImportFailure("the RTFD source must contain a direct regular TXT.rtf; links are not allowed") }) { text in
                guard text.isRegularFile, text.info.st_size >= 0,
                      text.info.st_size <= RichTextLimits.maximumSourceSize else {
                    throw ImportFailure("the RTFD text source is not a bounded regular file")
                }
                return try body(text)
            }
        }
    }
}
