import Foundation

/// Kopiert ein Verzeichnispaket ohne symbolische Verweise oder Sonderdateien in
/// einen privaten Arbeitsbaum. Jeder Quellknoten wird relativ zum bereits
/// geöffneten Elternverzeichnis mit `openat(..., O_NOFOLLOW)` gebunden; ein
/// paralleler Austausch eines Pfadbestandteils kann dadurch nicht unbemerkt aus
/// dem gewählten Paket herausführen.
enum VerifiedDirectoryStaging {
    struct StagingError: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private static let chunkSize = 262_144

    static func stage(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumFileBytes: Int,
        maximumTotalBytes: Int,
        maximumEntries: Int,
        describedAs subject: String
    ) throws {
        let sourceDescriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
        )
        guard sourceDescriptor >= 0 else {
            throw StagingError(reason: "\(subject) could not be opened as a directory")
        }
        defer { close(sourceDescriptor) }

        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0,
              sourceInfo.st_mode & S_IFMT == S_IFDIR else {
            throw StagingError(reason: "\(subject) is not a regular directory")
        }
        guard mkdir(destinationURL.path, 0o700) == 0 else {
            throw StagingError(reason: "the private package snapshot could not be created")
        }

        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }
        var totalBytes = 0
        var entryCount = 0
        try copyDirectory(
            sourceDescriptor: sourceDescriptor,
            destinationURL: destinationURL,
            maximumFileBytes: maximumFileBytes,
            maximumTotalBytes: maximumTotalBytes,
            maximumEntries: maximumEntries,
            subject: subject,
            totalBytes: &totalBytes,
            entryCount: &entryCount
        )
        succeeded = true
    }

    static func withTemporarySnapshot<T>(
        of sourceURL: URL,
        maximumFileBytes: Int,
        maximumTotalBytes: Int,
        maximumEntries: Int,
        describedAs subject: String,
        body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            ".poormans-text-package-inspection-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StagingError(reason: "the private inspection directory could not be created")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = root.appendingPathComponent("source.rtfd", isDirectory: true)
        try stage(
            from: sourceURL,
            to: snapshot,
            maximumFileBytes: maximumFileBytes,
            maximumTotalBytes: maximumTotalBytes,
            maximumEntries: maximumEntries,
            describedAs: subject
        )
        return try body(snapshot)
    }

    private static func copyDirectory(
        sourceDescriptor: Int32,
        destinationURL: URL,
        maximumFileBytes: Int,
        maximumTotalBytes: Int,
        maximumEntries: Int,
        subject: String,
        totalBytes: inout Int,
        entryCount: inout Int
    ) throws {
        let listingDescriptor = dup(sourceDescriptor)
        guard listingDescriptor >= 0, let directory = fdopendir(listingDescriptor) else {
            if listingDescriptor >= 0 { close(listingDescriptor) }
            throw StagingError(reason: "\(subject) could not be enumerated")
        }
        defer { closedir(directory) }

        while true {
            // `readdir` liefert `nil` sowohl am Ende der Liste als auch bei einem
            // Lesefehler; nur `errno` unterscheidet beides. Ohne die Prüfung galt
            // ein halb gelesenes Paket als vollständiger Snapshot
            // (Review-Fund 2026-09-03).
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw StagingError(reason: "\(subject) could not be enumerated completely")
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
                throw StagingError(reason: "\(subject) contains an unsafe entry name")
            }

            entryCount += 1
            guard entryCount <= maximumEntries else {
                throw StagingError(reason: "\(subject) contains too many entries")
            }

            var pathInfo = stat()
            guard fstatat(sourceDescriptor, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw StagingError(reason: "an entry in \(subject) could not be inspected")
            }
            let destination = destinationURL.appendingPathComponent(name)
            switch pathInfo.st_mode & S_IFMT {
            case S_IFDIR:
                let childDescriptor = openat(
                    sourceDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
                )
                guard childDescriptor >= 0 else {
                    throw StagingError(reason: "a directory in \(subject) changed during inspection")
                }
                defer { close(childDescriptor) }
                var openedInfo = stat()
                guard fstat(childDescriptor, &openedInfo) == 0,
                      openedInfo.st_mode & S_IFMT == S_IFDIR,
                      openedInfo.st_dev == pathInfo.st_dev,
                      openedInfo.st_ino == pathInfo.st_ino else {
                    throw StagingError(reason: "a directory in \(subject) changed during inspection")
                }
                guard mkdir(destination.path, 0o700) == 0 else {
                    throw StagingError(reason: "the private package snapshot could not be created")
                }
                try copyDirectory(
                    sourceDescriptor: childDescriptor,
                    destinationURL: destination,
                    maximumFileBytes: maximumFileBytes,
                    maximumTotalBytes: maximumTotalBytes,
                    maximumEntries: maximumEntries,
                    subject: subject,
                    totalBytes: &totalBytes,
                    entryCount: &entryCount
                )
            case S_IFREG:
                try copyFile(
                    sourceDirectoryDescriptor: sourceDescriptor,
                    name: name,
                    expectedInfo: pathInfo,
                    destinationURL: destination,
                    maximumFileBytes: maximumFileBytes,
                    maximumTotalBytes: maximumTotalBytes,
                    subject: subject,
                    totalBytes: &totalBytes
                )
            case S_IFLNK:
                throw StagingError(reason: "\(subject) contains a symbolic link")
            default:
                // Den betroffenen Namen mit Swift-Escaping ausgeben: Das
                // erklärt etwa eine FIFO anstelle von `TXT.rtf`, ohne dass
                // Steuerzeichen aus einem fremden Paket die Meldung umbrechen.
                throw StagingError(
                    reason: "\(subject) contains a non-regular entry named \(name.debugDescription)"
                )
            }
        }
    }

    private static func copyFile(
        sourceDirectoryDescriptor: Int32,
        name: String,
        expectedInfo: stat,
        destinationURL: URL,
        maximumFileBytes: Int,
        maximumTotalBytes: Int,
        subject: String,
        totalBytes: inout Int
    ) throws {
        let source = openat(
            sourceDirectoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK
        )
        guard source >= 0 else {
            throw StagingError(reason: "a file in \(subject) changed during inspection")
        }
        defer { close(source) }
        var openedInfo = stat()
        guard fstat(source, &openedInfo) == 0,
              openedInfo.st_mode & S_IFMT == S_IFREG,
              openedInfo.st_dev == expectedInfo.st_dev,
              openedInfo.st_ino == expectedInfo.st_ino else {
            throw StagingError(reason: "a file in \(subject) changed during inspection")
        }
        guard openedInfo.st_size <= Int64(maximumFileBytes),
              openedInfo.st_size <= Int64(maximumTotalBytes - totalBytes) else {
            throw StagingError(reason: "\(subject) exceeds the supported size limit")
        }

        let destination = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            0o600
        )
        guard destination >= 0 else {
            throw StagingError(reason: "the private package snapshot could not be written")
        }
        defer { close(destination) }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var fileBytes = 0
        while true {
            let readBytes = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(source, base, raw.count)
            }
            if readBytes == 0 { break }
            if readBytes < 0, errno == EINTR { continue }
            guard readBytes > 0 else {
                throw StagingError(reason: "a file in \(subject) could not be read")
            }
            fileBytes += readBytes
            totalBytes += readBytes
            guard fileBytes <= maximumFileBytes, totalBytes <= maximumTotalBytes else {
                throw StagingError(reason: "\(subject) exceeds the supported size limit")
            }
            try buffer.withUnsafeBytes { raw in
                guard var position = raw.baseAddress else { return }
                var remaining = readBytes
                while remaining > 0 {
                    let written = write(destination, position, remaining)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw StagingError(reason: "the private package snapshot could not be written")
                    }
                    position += written
                    remaining -= written
                }
            }
        }
    }
}
