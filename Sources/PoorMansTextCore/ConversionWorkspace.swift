import Foundation

/// Der Arbeitsbereich liegt auf demselben Dateisystem wie das endgültige Ziel.
final class ConversionWorkspace {
    let temporaryRoot: URL

    #if os(Linux)
    private let publication: LinuxOutputPublication
    #else
    private let outputURL: URL
    #endif

    var workDirectory: URL { temporaryRoot.appendingPathComponent("work", isDirectory: true) }
    var stagedOutput: URL { temporaryRoot.appendingPathComponent("result", isDirectory: true) }

    init(outputURL: URL) throws {
        #if os(Linux)
        publication = try LinuxOutputPublication(outputURL: outputURL)
        temporaryRoot = publication.temporaryRoot
        #else
        let root = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".poormans-text-\(UUID().uuidString).tmp",
            isDirectory: true
        )
        // Das Zielverzeichnis kann für andere Benutzer lesbar sein.
        guard mkdir(root.path, 0o700) == 0 else {
            throw ConversionError.fileSystemFailure(String(cString: strerror(errno)))
        }
        self.outputURL = outputURL
        temporaryRoot = root
        #endif
    }

    deinit {
        #if !os(Linux)
        try? FileManager.default.removeItem(at: temporaryRoot)
        #endif
    }

    func prepareDirectories() throws {
        let files = FileManager.default
        do {
            try files.createDirectory(at: workDirectory, withIntermediateDirectories: false)
            try files.createDirectory(at: stagedOutput, withIntermediateDirectories: false)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
    }

    func publish(validatePathDestination: () throws -> Void) throws {
        #if os(Linux)
        // Die Publikation prüft das gehaltene Elternverzeichnis selbst und behält
        // im Konfliktfall das konvertierte Ergebnis dort.
        try publication.publish()
        #else
        try validatePathDestination()
        let files = FileManager.default
        do {
            try files.moveItem(at: stagedOutput, to: outputURL)
        } catch {
            if files.fileExists(atPath: outputURL.path) {
                throw ConversionError.outputAlreadyExists(outputURL)
            }
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
        #endif
    }
}
