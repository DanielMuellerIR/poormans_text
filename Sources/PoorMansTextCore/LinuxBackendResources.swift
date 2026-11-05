#if os(Linux)
import Foundation
import Glibc
import CPMTLinux

enum LinuxBackendResources {
    static func script(named name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "py", subdirectory: "LinuxBackends") else {
            throw PlatformBackendUnavailable("local Linux \(name) helper")
        }
        return url
    }

    static func runPython(script name: String, arguments: [String], in directory: URL,
                          readOnlyPaths: [URL] = [], timeout: TimeInterval? = nil) throws -> ProcessResult {
        let script = try script(named: name)
        return try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", script.path] + arguments, currentDirectory: directory,
            captureStandardOutput: true, timeout: timeout ?? ConversionExecution.current?.processTimeout ?? 30,
            maximumCapturedBytes: 16 * 1024 * 1024,
            readOnlyPaths: [script] + readOnlyPaths, writeScope: directory)
    }
}

enum LinuxBackendWorkDirectory {
    static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let parent = ConversionExecution.current?.processWriteScope ?? FileManager.default.temporaryDirectory
        let parentFD = pmt_process_open_directory(parent.path)
        guard parentFD >= 0 else { throw ConversionError.fileSystemFailure("the local backend work parent could not be bound") }
        defer { close(parentFD) }
        let name = ".pmt-backend-\(UUID().uuidString)"
        guard mkdirat(parentFD, name, 0o700) == 0 else {
            throw ConversionError.fileSystemFailure(String(cString: strerror(errno)))
        }
        let descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            _ = pmt_remove_staging_at(parentFD, name, -1)
            throw ConversionError.fileSystemFailure("the local backend work directory could not be bound")
        }
        defer {
            _ = pmt_remove_staging_at(parentFD, name, descriptor)
            close(descriptor)
        }
        do {
            return try body(URL(fileURLWithPath: "/proc/\(getpid())/fd/\(descriptor)", isDirectory: true))
        } catch {
            let detail = error as NSError
            let cocoaFileError = detail.domain == NSCocoaErrorDomain
                && ((256...264).contains(detail.code) || (512...640).contains(detail.code))
            if detail.domain == NSPOSIXErrorDomain || cocoaFileError {
                throw ConversionError.fileSystemFailure(error.localizedDescription)
            }
            throw error
        }
    }
}
#endif
