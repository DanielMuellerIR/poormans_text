import Foundation
import ImageIO

/// ImageIO bekommt eine private Momentaufnahme aus dem gehaltenen Deskriptor.
/// Das verhindert auch SIGBUS durch Kürzung einer fremden, intern abgebildeten
/// Datei. /dev/fd bindet ImageIO danach an den geprüften Snapshot-Deskriptor.
final class VerifiedImageSource {
    private let file: VerifiedFile.Owned
    private let snapshot: VerifiedFile.Owned
    private let directory: URL
    let source: CGImageSource

    convenience init(at url: URL) throws {
        let file = try VerifiedFile.openRetained(at: url) { reason in
            switch reason {
            case .couldNotOpen(let detail): ImageAdapterError("the image source could not be opened: \(detail)")
            case .couldNotInspect: ImageAdapterError("the image source could not be inspected")
            case .couldNotRead: ImageAdapterError("the image source could not be read")
            }
        }
        try self.init(file: file)
    }

    init(file: VerifiedFile.Owned, allowClone: Bool = true) throws {
        guard file.file.isRegularFile else {
            throw ImageAdapterError("the image source is not a regular file")
        }
        guard file.file.info.st_size > 0,
              file.file.info.st_size <= Int64(ImageImportLimits.maximumSourceBytes) else {
            throw ImageAdapterError("the image source exceeds the supported size limit or is empty")
        }
        self.file = file
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(".poormans-text-image-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let destination = directory.appendingPathComponent("source")
        // APFS liefert eine unabhängige Copy-on-Write-Datei direkt aus dem FD.
        // Ohne Clone-Unterstützung bleibt der bestehende 256-KiB-Kopierpuffer.
        if !allowClone || fclonefileat(file.file.descriptor, AT_FDCWD, destination.path, UInt32(CLONE_NOOWNERCOPY)) != 0 {
            try VerifiedFileStaging.stage(from: file.file, to: destination,
                                          maximumBytes: ImageImportLimits.maximumSourceBytes,
                                          describedAs: "the image source")
        }
        let snapshot = try VerifiedFile.openRetained(at: destination) { _ in
            ImageAdapterError("the private image source could not be inspected")
        }
        guard snapshot.file.isRegularFile,
              snapshot.file.info.st_size == file.file.info.st_size else {
            throw ImageAdapterError("the image source changed while it was being copied")
        }
        self.snapshot = snapshot
        self.directory = directory
        let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(snapshot.file.descriptor)")
        guard let source = CGImageSourceCreateWithURL(
            descriptorURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ImageAdapterError("the image format is unsupported or unreadable")
        }
        self.source = source
        try validateUnchanged()
        succeeded = true
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Ein Deskriptor verhindert Pfadaustausch, aber keine Änderung am Objekt.
    /// Solche Änderungen dürfen keine erfolgreiche Bildprobe/OCR liefern.
    func validateUnchanged() throws {
        var current = stat()
        let original = file.file.info
        guard fstat(file.file.descriptor, &current) == 0,
              current.st_size == original.st_size,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else {
            throw ImageAdapterError("the image source changed while it was being read")
        }
    }
}
