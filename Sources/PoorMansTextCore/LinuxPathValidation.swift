#if os(Linux)
import Foundation
import Glibc

enum LinuxPathValidation {
    static func validate(_ url: URL) throws {
        guard url.isFileURL else { throw ConversionError.fileSystemFailure("the input must be a local file URL") }
        guard !url.path.contains("\0") else { throw ConversionError.fileSystemFailure("the file path contains a NUL character") }
        var candidate = url
        while true {
            var failureCode: Int32 = 0
            var unresolvedLink = false
            let valid: Bool? = candidate.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                guard let resolved = realpath(path, nil) else {
                    failureCode = errno
                    var metadata = stat()
                    unresolvedLink = lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK
                    return nil
                }
                defer { free(resolved) }
                return String(validatingCString: resolved) != nil
            }
            if let valid {
                guard valid else {
                    throw ConversionError.fileSystemFailure("the resolved file path contains a name that is not valid UTF-8")
                }
                return
            }
            guard failureCode == ENOENT, !unresolvedLink else {
                throw ConversionError.fileSystemFailure("the file path could not be resolved safely for UTF-8 validation")
            }
            // Neue Ziele existieren noch nicht; ihre vorhandenen Eltern dürfen
            // ebenfalls nicht durch Foundations Ersatzzeichen umgedeutet werden.
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return }
            candidate = parent
        }
    }
}
#endif
