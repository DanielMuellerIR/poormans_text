import Foundation

/// Führt ein Hilfsprogramm aus, verwirft dessen Standardausgabe und liefert
/// Exit-Status und vollständige Fehlerausgabe zurück.
enum CapturedProcess {
    /// Reihenfolge ist entscheidend: Die Fehler-Pipe wird bis EOF gelesen,
    /// BEVOR auf das Prozessende gewartet wird. Ein Kindprozess, der mehr
    /// schreibt, als der Pipe-Puffer fasst, würde sonst blockieren, während
    /// `waitUntilExit()` gleichzeitig auf ihn wartet — ein Deadlock.
    static func run(
        executable: URL,
        arguments: [String]
    ) throws -> (status: Int32, standardError: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let standardError = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let message = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, message)
    }
}
