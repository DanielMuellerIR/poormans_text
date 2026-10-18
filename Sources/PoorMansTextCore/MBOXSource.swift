import Foundation
import Darwin

/// Apple Mail exportiert das Postfach als direktes Mitglied `mbox`. Andere
/// Paketdateien (etwa table_of_contents) sind keine Nachrichtenquellen.
enum MBOXSource {
    static func withMailbox<T>(at url: URL, body: (VerifiedFile, Bool) throws -> T) throws -> T {
        try VerifiedFile.open(at: url, failure: { _ in ImportFailure("the MBOX source could not be opened") }) { source in
            if source.isRegularFile {
                try validate(source)
                return try body(source, false)
            }
            guard source.info.st_mode & S_IFMT == S_IFDIR, url.pathExtension.lowercased() == "mbox" else {
                throw ImportFailure("the MBOX source must be a regular file or an Apple Mail .mbox export package")
            }
            return try VerifiedFile.openMember(named: "mbox", in: source.descriptor,
                sourceURL: url.appendingPathComponent("mbox"),
                failure: { _ in ImportFailure("the Apple Mail export must contain a direct regular file named mbox; links are not allowed") }) { mailbox in
                try validate(mailbox)
                guard mailbox.info.st_nlink == 1 else { throw ImportFailure("the Apple Mail mailbox data must not be a hard link") }
                return try body(mailbox, true)
            }
        }
    }

    private static func validate(_ file: VerifiedFile) throws {
        guard file.isRegularFile, file.info.st_size >= 0, file.info.st_size <= MBOXReader.maximumArchiveBytes else {
            throw ImportFailure("the MBOX mailbox data must be a regular file within the 512 MiB archive limit")
        }
    }
}
