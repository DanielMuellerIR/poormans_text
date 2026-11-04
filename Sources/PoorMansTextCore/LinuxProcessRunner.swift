#if os(Linux)
import Foundation
import Glibc
import CPMTLinux

package enum LinuxProcessRunner {
    package static func run(
        executable: URL, arguments: [String], currentDirectory: URL,
        captureStandardOutput: Bool, timeout: TimeInterval?,
        cancellation: ConversionCancellationToken?, terminationGrace: TimeInterval,
        maximumCapturedBytes: Int, processGuardExecutable: URL?,
        readOnlyPaths: [URL], writeScope: URL?
    ) throws -> ProcessResult {
        let token = cancellation.map { ConversionCancellationToken(parent: $0) }
            ?? ConversionExecution.current?.cancellation ?? ConversionCancellationToken()
        let timeout = timeout ?? ConversionExecution.current?.processTimeout
        guard timeout.map({ $0.isFinite && $0 > 0 }) ?? true,
              terminationGrace.isFinite, terminationGrace >= 0,
              terminationGrace * 1000 <= Double(Int32.max),
              maximumCapturedBytes > 0, maximumCapturedBytes < Int.max else {
            throw failure("invalid process limits")
        }
        try token.checkCancellation()
        let manager = FileManager.default
        let scope = writeScope ?? ConversionExecution.current?.processWriteScope ?? currentDirectory
        guard scope.isFileURL, currentDirectory.isFileURL,
              scope.path != "/", contains(scope.path, currentDirectory.path),
              scope.standardizedFileURL.path == scope.path,
              currentDirectory.standardizedFileURL.path == currentDirectory.path else {
            throw failure("the process working directory must belong to its explicit writable scope")
        }
        let scopeFD = pmt_process_open_directory(scope.path)
        guard scopeFD >= 0 else { throw failure("the process writable scope could not be bound safely") }
        defer { close(scopeFD) }
        let relativeDirectory = currentDirectory.path == scope.path ? "" : String(currentDirectory.path.dropFirst(scope.path.count + 1))
        let directoryFD = pmt_process_open_relative_directory(scopeFD, relativeDirectory)
        guard directoryFD >= 0 else { throw failure("the process working directory could not be bound safely") }
        defer { close(directoryFD) }
        let heldScopePath = "/proc/\(getpid())/fd/\(scopeFD)"
        let heldDirectoryPath = "/proc/\(getpid())/fd/\(directoryFD)"
        func hostSource(_ path: String) -> String {
            if contains(currentDirectory.path, path) { return heldDirectoryPath + path.dropFirst(currentDirectory.path.count) }
            if contains(scope.path, path) { return heldScopePath + path.dropFirst(scope.path.count) }
            return path
        }
        var isDirectory: ObjCBool = false
        let guardURL: URL
        if let processGuardExecutable {
            guardURL = processGuardExecutable
        } else if let host = Bundle.main.executableURL {
            guardURL = host.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("poormans-text-process-guard")
        } else {
            throw failure("the local PMT process guard must be installed beside the host executable or supplied explicitly")
        }
        for tool in [executable, guardURL, URL(fileURLWithPath: "/usr/bin/bwrap")] {
            guard tool.isFileURL, manager.isExecutableFile(atPath: tool.path),
                  manager.fileExists(atPath: tool.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw failure("the required local executable is missing: \(tool.lastPathComponent)")
            }
        }
        let identifier = UUID().uuidString
        let errorName = ".process-\(identifier).stderr"
        let outputName = ".process-\(identifier).stdout"
        let infoName = ".process-\(identifier).namespace"
        let errorHandle = try capture(in: directoryFD, name: errorName)
        var outputHandle: FileHandle?
        var infoHandle: FileHandle?
        defer {
            for (name, handle) in [(errorName, Optional(errorHandle)), (outputName, outputHandle), (infoName, infoHandle)] {
                if let handle {
                    _ = pmt_process_unlink_owned_capture(directoryFD, name, handle.fileDescriptor)
                    try? handle.close()
                }
            }
        }
        if captureStandardOutput { outputHandle = try capture(in: directoryFD, name: outputName) }
        infoHandle = try capture(in: directoryFD, name: infoName)

        var mappings = [(source: scope.path, destination: "/pmt/work-scope")]
        if currentDirectory.path != scope.path { mappings.append((currentDirectory.path, "/pmt/work-dir")) }
        var boundPaths = [heldScopePath, heldDirectoryPath]
        func boundPath(_ path: String) -> String {
            boundPaths.append(path)
            return "pmt-fd:\(boundPaths.count - 1)"
        }
        var sandbox = ["--unshare-pid", "--unshare-net", "--as-pid-1", "--new-session"]
        // Nur Systemlaufzeit und ausdrücklich gebundene Eingaben sind sichtbar.
        // Insbesondere wird kein schreibbarer Host-Elternbaum übernommen.
        for path in ["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc/ld.so.cache", "/etc/fonts", "/etc/localtime"] {
            if manager.fileExists(atPath: path) { sandbox += ["--ro-bind", path, path] }
        }
        sandbox += ["--dir", "/pmt", "--dir", "/pmt/input", "--bind-fd", "pmt-fd:0", "/pmt/work-scope",
                    "--bind-fd", "pmt-fd:1", "/pmt/work-dir"]
        if let outputHandle {
            sandbox += ["--bind-fd", boundPath("/proc/\(getpid())/fd/\(outputHandle.fileDescriptor)"), "/pmt/capture-stdout"]
        }
        for (index, source) in readOnlyPaths.enumerated() {
            guard source.isFileURL, source.path != "/", source.standardizedFileURL.path == source.path,
                  manager.fileExists(atPath: source.path) else {
                throw failure("a required read-only process input is unavailable")
            }
            let destination = "/pmt/input/\(index)"
            mappings.append((source.path, destination))
            sandbox += ["--ro-bind-fd", boundPath(hostSource(source.path)), destination]
        }
        mappings.sort { $0.source.count > $1.source.count }
        func mapped(_ path: String) -> String {
            for entry in mappings where contains(entry.source, path) {
                return entry.destination + path.dropFirst(entry.source.count)
            }
            return path
        }
        let sandboxExecutable: String
        if ["/usr", "/bin", "/sbin", "/lib", "/lib64"].contains(where: { contains($0, executable.path) }) {
            sandboxExecutable = executable.path
        } else {
            sandboxExecutable = "/pmt/tool/" + executable.lastPathComponent
            sandbox += ["--dir", "/pmt/tool", "--ro-bind-fd", boundPath(hostSource(executable.path)), sandboxExecutable]
        }
        // /proc/<Host-PID>/fd/... wird gebunden, bevor das private /proc entsteht.
        sandbox += ["--ro-bind-fd", boundPath(hostSource(guardURL.path)), "/pmt/guard", "--tmpfs", "/tmp",
                    "--proc", "/proc", "--dev", "/dev", "--chdir", "/pmt/work-dir",
                    "--info-fd", "1", "--", "/pmt/guard", "--pmt-process-guard-v1",
                    captureStandardOutput ? "/pmt/capture-stdout" : "/dev/null",
                    String(Int(terminationGrace * 1000)), "--", sandboxExecutable]
        sandbox += arguments.map(mapped)

        let lifetime = Pipe()
        guard fcntl(lifetime.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(lifetime.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw failure("the process lifetime channel could not be protected")
        }
        let process = Process()
        process.executableURL = guardURL
        process.arguments = ["--pmt-sandbox-launch-v1", String(boundPaths.count)] + boundPaths + ["--", "/usr/bin/bwrap"] + sandbox
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/tmp", "TMPDIR": "/tmp", "LANG": "C.UTF-8"]
        process.standardInput = lifetime
        process.standardOutput = infoHandle
        process.standardError = errorHandle
        var wrapperFD: Int32 = -1
        var namespaceFD: Int32 = -1
        var launched = false
        var completed = false
        func finish() {
            if completed { return }
            try? lifetime.fileHandleForReading.close()
            try? lifetime.fileHandleForWriting.close()
            // Wrapperverlust ist noch keine Namespace-Endebestätigung. Der
            // gebundene PID-1-pidfd bleibt die Barriere vor Capture-/Work-Cleanup.
            if namespaceFD >= 0 { _ = pmt_process_pidfd_ready(namespaceFD, -1) }
            if wrapperFD >= 0 { _ = pmt_process_pidfd_ready(wrapperFD, -1) }
            if launched { process.waitUntilExit() }
            completed = true
        }
        defer {
            finish()
            if namespaceFD >= 0 { close(namespaceFD) }
            if wrapperFD >= 0 { close(wrapperFD) }
        }
        try process.run()
        launched = true
        try lifetime.fileHandleForReading.close()
        wrapperFD = pmt_process_pidfd_open_owned(process.processIdentifier, getpid())
        guard wrapperFD >= 0 else { throw failure("Linux pidfd supervision is unavailable") }
        let setupDeadline = ProcessInfo.processInfo.systemUptime + 5
        while namespaceFD < 0 {
            try token.checkCancellation()
            let info = try read(infoHandle!, maximumBytes: 4096)
            if let object = try? JSONSerialization.jsonObject(with: info) as? [String: Any],
               let child = object["child-pid"] as? NSNumber, child.int32Value > 1 {
                namespaceFD = pmt_process_pidfd_open_owned(child.int32Value, getpid())
                guard namespaceFD >= 0 else { throw failure("the private PID namespace could not be bound") }
                break
            }
            let wrapper = pmt_process_pidfd_ready(wrapperFD, 10)
            guard wrapper == 0, ProcessInfo.processInfo.systemUptime < setupDeadline else {
                let diagnostic = String(decoding: try read(errorHandle, maximumBytes: maximumCapturedBytes), as: UTF8.self)
                throw failure("the required Linux PID/network sandbox could not start: \(diagnostic)")
            }
        }
        try token.checkCancellation()
        guard pmt_process_write_control(lifetime.fileHandleForWriting.fileDescriptor, 1) == 0 else {
            throw failure("the Linux process guard could not start the conversion tool")
        }
        let started = ProcessInfo.processInfo.systemUptime
        var stopping = false
        while true {
            let namespace = pmt_process_pidfd_ready(namespaceFD, 10)
            if namespace == 1 { break }
            if namespace < 0 { throw failure("the Linux namespace supervision failed") }
            if pmt_process_pidfd_ready(wrapperFD, 0) != 0 {
                try? lifetime.fileHandleForWriting.close()
                throw failure("the Linux sandbox wrapper ended before its PID namespace")
            }
            if let timeout, ProcessInfo.processInfo.systemUptime - started >= timeout { token.stop(.processTimedOut) }
            for handle in [errorHandle, outputHandle].compactMap({ $0 }) {
                var metadata = stat()
                if fstat(handle.fileDescriptor, &metadata) != 0 {
                    token.stop(failure("the conversion tool output could not be inspected"))
                } else if metadata.st_size > maximumCapturedBytes {
                    token.stop(failure("the conversion tool exceeded its output limit"))
                }
            }
            if token.isCancelled && !stopping {
                stopping = true
                if pmt_process_write_control(lifetime.fileHandleForWriting.fileDescriptor, 2) != 0 {
                    try? lifetime.fileHandleForWriting.close()
                }
            }
        }
        finish()
        try token.checkCancellation()
        let errorData = try read(errorHandle, maximumBytes: maximumCapturedBytes)
        let outputData = captureStandardOutput ? try read(outputHandle!, maximumBytes: maximumCapturedBytes) : Data()
        return ProcessResult(status: process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus,
                             standardOutput: String(decoding: outputData, as: UTF8.self),
                             standardError: String(decoding: errorData, as: UTF8.self))
    }

    private static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func failure(_ message: String) -> ConversionError { .fileSystemFailure(message) }

    private static func capture(in directory: Int32, name: String) throws -> FileHandle {
        let descriptor = openat(directory, name, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw failure("the process capture file could not be created") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func read(_ handle: FileHandle, maximumBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumBytes + 1))
        while data.count <= maximumBytes {
            let requested = min(buffer.count, maximumBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                pread(handle.fileDescriptor, bytes.baseAddress!, requested, off_t(data.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("the process capture file could not be read")
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw failure("the conversion tool exceeded its output limit")
    }
}
#endif
