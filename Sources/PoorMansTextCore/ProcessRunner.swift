import Foundation
import Darwin

package struct ProcessResult: Sendable {
    package let status: Int32
    package let standardOutput: String
    package let standardError: String
}

/// Startet ein Hilfsprogramm mit Zeitlimit, Abbruch-Token und Ausgabegrenze.
/// `package`-sichtbar, weil auch die App ihre Hilfsprozesse (Homebrew,
/// osascript) über genau diesen Weg laufen lässt: Ein zweiter Prozessstarter
/// ohne Zeitlimit und Abbruch hatte die App bei hängendem Homebrew dauerhaft
/// gesperrt (Roadmap-Punkt, 2026-09-10). Öffentliche API bleibt das nicht.
package enum ProcessRunner {
    package static func run(
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

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: executable.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, fileManager.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        // Der Gruppenleiter bleibt bis zur Identitätsprüfung am Pipe-Eingang
        // stehen. Ein sofort endendes Werkzeug könnte sonst schon vor getpgid
        // verschwinden und seine Kindprozesse unüberwacht zurücklassen.
        let startup = Pipe()
        defer {
            try? startup.fileHandleForReading.close()
            try? startup.fileHandleForWriting.close()
        }
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "IFS= read -r startup || exit 125\nexec \"$@\" < /dev/null", "poormans-text-tool", executable.path] + arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = startup
        process.standardOutput = outputHandle ?? FileHandle.nullDevice
        process.standardError = errorHandle

        try process.run()
        let processID = process.processIdentifier
        try? startup.fileHandleForReading.close()
        // Foundation legt auf macOS eine eigene Prozessgruppe an. Nur eine
        // tatsächlich getrennte Gruppe benutzen, niemals die Gruppe des Hosts.
        let ownsGroup = getpgid(processID) == processID && processID != getpgrp()
        guard ownsGroup else {
            try? startup.fileHandleForWriting.close()
            process.waitUntilExit()
            throw ConversionError.fileSystemFailure("the conversion tool could not establish its own process group")
        }
        let signalTarget = -processID
        do {
            try token.checkCancellation()
            try startup.fileHandleForWriting.write(contentsOf: Data([0x0A]))
            try startup.fileHandleForWriting.close()
        } catch {
            kill(signalTarget, SIGKILL)
            process.waitUntilExit()
            throw error
        }
        let started = ProcessInfo.processInfo.systemUptime
        var terminationStarted: TimeInterval?
        while process.isRunning || (ownsGroup && kill(signalTarget, 0) == 0) {
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
            // Auch nach erfolgreichem Ende des Hauptprozesses dürfen Kinder
            // keine Capture-Deskriptoren offenhalten und weiterarbeiten.
            if token.isCancelled || !process.isRunning {
                if let terminationStarted {
                    if now - terminationStarted >= terminationGrace {
                        // Die eigene Prozessgruppe beenden; Foundation erntet
                        // anschließend deren Hauptprozess.
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
