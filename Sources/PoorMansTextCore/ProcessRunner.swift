import Foundation
import Darwin

struct ProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        captureStandardOutput: Bool = false,
        timeout: TimeInterval? = nil,
        cancellation: ConversionCancellationToken? = nil,
        terminationGrace: TimeInterval = 0.25,
        maximumCapturedBytes: Int = 16 * 1024 * 1024
    ) throws -> ProcessResult {
        let token = cancellation.map { ConversionCancellationToken(parent: $0) }
            ?? ConversionExecution.current?.cancellation ?? ConversionCancellationToken()
        let timeout = timeout ?? ConversionExecution.current?.processTimeout
        guard timeout.map({ $0.isFinite && $0 > 0 }) ?? true,
              terminationGrace.isFinite && terminationGrace >= 0, maximumCapturedBytes > 0 && maximumCapturedBytes < Int.max else {
            throw ConversionError.fileSystemFailure("invalid process limits")
        }
        try token.checkCancellation()
        let fileManager = FileManager.default
        let identifier = UUID().uuidString
        let errorURL = currentDirectory.appendingPathComponent(".process-\(identifier).stderr")
        let outputURL = currentDirectory.appendingPathComponent(".process-\(identifier).stdout")

        guard fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if captureStandardOutput,
           !fileManager.createFile(atPath: outputURL.path, contents: nil) {
            try? fileManager.removeItem(at: errorURL)
            throw CocoaError(.fileWriteUnknown)
        }

        let errorHandle: FileHandle
        do {
            errorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            try? fileManager.removeItem(at: errorURL)
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
        let outputHandle: FileHandle?
        do {
            outputHandle = captureStandardOutput
                ? try FileHandle(forWritingTo: outputURL)
                : nil
        } catch {
            try? errorHandle.close()
            try? fileManager.removeItem(at: errorURL)
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
        defer {
            try? errorHandle.close()
            try? outputHandle?.close()
            try? fileManager.removeItem(at: errorURL)
            try? fileManager.removeItem(at: outputURL)
        }

        let process = Process()

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle ?? FileHandle.nullDevice
        process.standardError = errorHandle

        try process.run()
        let processID = process.processIdentifier
        // Foundation legt auf macOS eine eigene Prozessgruppe an. Nur eine
        // tatsächlich getrennte Gruppe benutzen, niemals die Gruppe des Hosts.
        let ownsGroup = getpgid(processID) == processID && processID != getpgrp()
        let signalTarget = ownsGroup ? -processID : processID
        let started = ProcessInfo.processInfo.systemUptime
        var terminationStarted: TimeInterval?
        while process.isRunning || (terminationStarted != nil && ownsGroup && kill(signalTarget, 0) == 0) {
            let now = ProcessInfo.processInfo.systemUptime
            if let timeout, now - started >= timeout { token.stop(.processTimedOut) }
            // Die Kindprozesse schreiben in Dateien statt Pipes. Das verhindert
            // Pipe-Deadlocks; Größenlimit und begrenztes Lesen schützen Speicher.
            for handle in [errorHandle, outputHandle].compactMap({ $0 }) {
                var metadata = stat()
                if fstat(handle.fileDescriptor, &metadata) == 0 && metadata.st_size > maximumCapturedBytes {
                    token.stop(.fileSystemFailure("the conversion tool exceeded its output limit"))
                }
            }
            if token.isCancelled {
                if let terminationStarted {
                    if now - terminationStarted >= terminationGrace {
                        // Nur den noch laufenden, von diesem Aufruf gestarteten
                        // Prozess treffen; Foundation erntet ihn anschließend.
                        kill(signalTarget, SIGKILL)
                        break
                    }
                } else {
                    terminationStarted = now
                    kill(signalTarget, SIGTERM)
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        try token.checkCancellation()
        try errorHandle.close()
        try outputHandle?.close()

        func boundedRead(_ url: URL) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumCapturedBytes + 1) ?? Data()
            guard data.count <= maximumCapturedBytes else {
                throw ConversionError.fileSystemFailure("the conversion tool exceeded its output limit")
            }
            return data
        }
        let errorData = try boundedRead(errorURL)
        let outputData = captureStandardOutput ? try boundedRead(outputURL) : Data()

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
