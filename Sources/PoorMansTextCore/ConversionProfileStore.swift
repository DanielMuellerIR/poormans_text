import Foundation
import Darwin

/// Benannte Profile liegen lokal; Publikation per Hardlink überschreibt auch
/// bei konkurrierenden Schreibern oder Symlinks kein vorhandenes Ziel.
public struct ConversionProfileStore: Sendable {
    public let directory: URL
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PoorMansText/Profiles", isDirectory: true)
    }
    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }
    private func filename(_ name: String) throws -> String {
        _ = try ConversionProfile(name: name)
        let canonical = name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
        return ConversionFileFingerprint.digest(Data(canonical.utf8)) + ".json"
    }
    private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T {
        guard directory.isFileURL else { throw ConversionProfileError("The profile store must be a local directory.", kind: .fileSystem) }
        if create {
            var info = stat()
            if lstat(directory.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR {
                throw ConversionProfileError("The profile store path is not a regular directory.", kind: .fileSystem)
            }
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw ConversionProfileError("The profile directory could not be created.", kind: .fileSystem) }
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ConversionProfileError("The profile directory could not be opened.", kind: errno == ENOENT ? .missing : .fileSystem) }
        defer { close(fd) }
        return try body(fd)
    }
    private func storedNames() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 2_048 else { throw ConversionProfileError("The profile directory exceeds 2048 entries.") }
        let files = names.filter { $0.range(of: #"^[a-f0-9]{64}\.json$"#, options: .regularExpression) != nil }
        guard files.count <= 256 else { throw ConversionProfileError("The profile store exceeds 256 profiles.") }
        return files.sorted()
    }
    private func read(_ fd: Int32) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= ConversionProfile.maximumBytes else {
            throw ConversionProfileError("A profile must be a regular file of at most 256 KiB.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try ConversionExecution.check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ConversionProfileError("A profile could not be read.", kind: .fileSystem) }
            guard count <= ConversionProfile.maximumBytes - data.count else { throw ConversionProfileError("The profile exceeds 256 KiB.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    private func load(_ name: String, directoryFD: Int32) throws -> ConversionProfile {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ConversionProfileError("The profile could not be opened.", kind: errno == ENOENT ? .missing : .fileSystem) }
        defer { close(fd) }
        let profile = try ConversionProfile.decode(read(fd))
        guard try filename(profile.name) == name else { throw ConversionProfileError("The stored profile name does not match its file.") }
        return profile
    }
    public func load(named name: String) throws -> ConversionProfile {
        let path = try filename(name)
        return try withDirectory(create: false) { try load(path, directoryFD: $0) }
    }
    public func profiles() throws -> [ConversionProfile] {
        if !FileManager.default.fileExists(atPath: directory.path) { return [] }
        return try withDirectory(create: false) { fd in
            try storedNames().map { try load($0, directoryFD: fd) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    public func save(_ profile: ConversionProfile, allowLocalTargets: Bool = false) throws {
        try profile.requireLocalPermission(allowLocalTargets)
        let data = try profile.encoded(), name = try filename(profile.name)
        try withDirectory(create: true) { fd in
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConversionProfileError("The profile store is busy; try again.", kind: .fileSystem) }
            defer { flock(fd, LOCK_UN) }
            guard try storedNames().count < 256 else { throw ConversionProfileError("The profile store is limited to 256 profiles.") }
            try Self.publish(data, named: name, directoryFD: fd)
        }
    }
    /// Explizite Bearbeitung erfordert den zuvor gelesenen Stand. Alle eigenen
    /// Schreiber verwenden dieselbe Sperre; veraltete Fenster ersetzen nichts.
    public func update(_ profile: ConversionProfile, replacing expected: ConversionProfile, allowLocalTargets: Bool = false) throws {
        try profile.requireLocalPermission(allowLocalTargets)
        let data = try profile.encoded(), name = try filename(expected.name)
        guard try filename(profile.name) == name else { throw ConversionProfileError("Use a new profile to change its name.") }
        try withDirectory(create: false) { fd in
            try withEditLock(fd) {
                guard try load(name, directoryFD: fd) == expected else { throw ConversionProfileError("The saved profile changed. Reload it before editing.", kind: .fileSystem) }
                try Self.publish(data, named: name, directoryFD: fd, replacing: true)
            }
        }
    }
    public func delete(_ expected: ConversionProfile) throws {
        let name = try filename(expected.name)
        try withDirectory(create: false) { fd in
            try withEditLock(fd) {
                guard try load(name, directoryFD: fd) == expected else { throw ConversionProfileError("The saved profile changed. Reload it before deleting.", kind: .fileSystem) }
                guard unlinkat(fd, name, 0) == 0 else { throw ConversionProfileError("The profile could not be deleted.", kind: .fileSystem) }
            }
        }
    }
    private func withEditLock<T>(_ fd: Int32, _ body: () throws -> T) throws -> T {
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConversionProfileError("The profile store is busy; try again.", kind: .fileSystem) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    public static func readProfile(at url: URL) throws -> ConversionProfile {
        do {
            let data = try VerifiedFileStaging.withVerifiedSource(at: url, maximumBytes: ConversionProfile.maximumBytes, describedAs: "the imported profile") { source, _ in
                var data = Data()
                _ = try source.readChunks(maximumBytes: ConversionProfile.maximumBytes, chunkSize: 16_384, budgetExceeded: { ConversionProfileError("The profile exceeds 256 KiB.") }) {
                    data.append(contentsOf: $0); return true
                }
                return data
            }
            return try .decode(data)
        } catch let error as ConversionProfileError { throw error }
        catch {
            try ConversionExecution.check()
            throw ConversionProfileError("The imported profile could not be read as a regular file within its size limit.", kind: FileManager.default.fileExists(atPath: url.path) ? .invalid : .missing)
        }
    }

    public static func export(_ profile: ConversionProfile, to url: URL, allowLocalTargets: Bool = false) throws {
        try profile.requireLocalPermission(allowLocalTargets)
        let data = try profile.encoded()
        guard url.isFileURL, !url.lastPathComponent.isEmpty, ![".", ".."].contains(url.lastPathComponent) else { throw ConversionProfileError("The profile export needs a local file path.") }
        let store = Self(directory: url.deletingLastPathComponent())
        try store.withDirectory(create: false) { try publish(data, named: url.lastPathComponent, directoryFD: $0) }
    }
    private static func publish(_ data: Data, named name: String, directoryFD: Int32, replacing: Bool = false) throws {
        let temporary = ".profile-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ConversionProfileError("The profile staging file could not be created.", kind: .fileSystem) }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try ConversionExecution.check()
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ConversionProfileError("The profile could not be written.", kind: .fileSystem) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ConversionProfileError("The profile staging file could not be synchronized.", kind: .fileSystem) }
        if replacing {
            guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw ConversionProfileError("The profile could not be updated.", kind: .fileSystem) }
            return
        }
        guard linkat(directoryFD, temporary, directoryFD, name, 0) == 0 else {
            throw ConversionProfileError(errno == EEXIST ? "The profile name or export target already exists; nothing was overwritten." : "The profile could not be published.", kind: errno == EEXIST ? .collision : .fileSystem)
        }
    }
}
