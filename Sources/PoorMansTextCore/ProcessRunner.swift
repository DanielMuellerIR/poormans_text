import Foundation

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
        captureStandardOutput: Bool = false
    ) throws -> ProcessResult {
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
        process.standardOutput = outputHandle ?? FileHandle.nullDevice
        process.standardError = errorHandle

        try process.run()
        process.waitUntilExit()
        try errorHandle.close()
        try outputHandle?.close()

        let errorData = try Data(contentsOf: errorURL)
        let outputData = captureStandardOutput
            ? try Data(contentsOf: outputURL)
            : Data()

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
