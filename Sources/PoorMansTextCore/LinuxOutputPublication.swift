#if os(Linux)
import Foundation
import Glibc
import CPMTLinux

/// Hält Ausgabeeltern und privaten Arbeitsbereich bis nach Publikation/Cleanup.
/// Pfadwechsel werden als Konflikt gemeldet; vollständige Ergebnisse bleiben erhalten.
final class LinuxOutputPublication {
    private let outputURL: URL
    private let parentURL: URL
    private let parentFD: Int32
    private let stagingFD: Int32
    private let stagingName: String
    private var preserveStaging = false
    let temporaryRoot: URL

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        parentURL = outputURL.deletingLastPathComponent()
        try Self.validateName(outputURL.lastPathComponent)
        parentFD = try Self.openDirectory(parentURL)
        stagingName = ".poormans-text-\(UUID().uuidString).tmp"
        guard mkdirat(parentFD, stagingName, 0o700) == 0 else {
            let code = errno
            close(parentFD)
            throw Self.failure(code)
        }
        let opened = openat(parentFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else {
            let code = errno
            _ = pmt_remove_staging_at(parentFD, stagingName, -1)
            close(parentFD)
            throw Self.failure(code)
        }
        stagingFD = opened
        // Die PID bleibt für externe Werkzeuge eindeutig; deren eigener /proc/self
        // bezeichnet einen anderen Prozess und CLOEXEC schließt diese FDs dort.
        temporaryRoot = URL(fileURLWithPath: "/proc/\(getpid())/fd/\(opened)", isDirectory: true)
    }

    deinit {
        cleanup()
        close(stagingFD)
        close(parentFD)
    }

    func cleanup() {
        if !preserveStaging { _ = pmt_remove_staging_at(parentFD, stagingName, stagingFD) }
    }

    func publish(beforeRename: () throws -> Void = {}, afterRename: () throws -> Void = {}) throws {
        do {
            try requireUnchangedParent()
            try beforeRename()
            guard pmt_renameat2_noreplace(stagingFD, "result", parentFD, outputURL.lastPathComponent) == 0 else {
                let code = errno
                if code == EEXIST { throw ConversionError.outputAlreadyExists(outputURL) }
                throw Self.failure(code)
            }
            // Nach erfolgreichem Rename darf ein Fehler den kompletten Output
            // weder löschen noch als publiziert am inzwischen anderen Pfad melden.
            preserveStaging = true
            try afterRename()
            try requireUnchangedParent()
            preserveStaging = false
        } catch {
            throw error
        }
    }

    private func requireUnchangedParent() throws {
        let current: Int32
        do { current = try Self.openDirectory(parentURL) }
        catch {
            preserveStaging = true
            throw changedParent()
        }
        defer { close(current) }
        var held = stat()
        var observed = stat()
        guard fstat(parentFD, &held) == 0, fstat(current, &observed) == 0,
              held.st_dev == observed.st_dev, held.st_ino == observed.st_ino else {
            preserveStaging = true
            throw changedParent()
        }
    }

    private func changedParent() -> ConversionError {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = readlink("/proc/\(getpid())/fd/\(parentFD)", &buffer, buffer.count - 1)
        let retained = count >= 0 ? String(bytes: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? "[held directory path is not valid UTF-8]" : "[held directory path unavailable]"
        return .fileSystemFailure("output parent changed (ESTALE); complete conversion data retained in held directory: \(retained); staging: \(stagingName); target: \(outputURL.lastPathComponent)")
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.path.hasPrefix("/") else { throw failure(EINVAL) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(errno) }
        do {
            for component in url.pathComponents.dropFirst() {
                try validateName(component)
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure(errno) }
                close(fd)
                fd = next
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw failure(EINVAL)
        }
    }

    private static func failure(_ code: Int32) -> ConversionError {
        .fileSystemFailure("\(String(cString: strerror(code))) (errno \(code))")
    }
}
#endif
