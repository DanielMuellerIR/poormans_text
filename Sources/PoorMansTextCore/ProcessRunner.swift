import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let standardError: String
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL
    ) throws -> ProcessResult {
        let fileManager = FileManager.default
        let identifier = UUID().uuidString
        let errorURL = currentDirectory.appendingPathComponent(".process-\(identifier).stderr")

        guard fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? errorHandle.close()
            try? fileManager.removeItem(at: errorURL)
        }

        let process = Process()

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle

        try process.run()
        process.waitUntilExit()
        try errorHandle.close()

        let errorData = try Data(contentsOf: errorURL)

        return ProcessResult(
            status: process.terminationStatus,
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
