import Foundation

/// Kopiert eine Eingabedatei in den Arbeitsordner — und zwar so, dass zwischen
/// Prüfung und Kopie nichts ausgetauscht werden kann.
///
/// Die frühere Reihenfolge war: den PFAD prüfen (reguläre Datei, höchstens
/// 1 GiB) und den Pfad danach mit `copyItem` kopieren. Wird der Pfad dazwischen
/// durch eine größere Datei oder ein Verzeichnis ersetzt — oder wächst die Datei
/// während des Kopierens —, war die vollständige, unbegrenzte Kopie schon
/// geschrieben, bevor die nachgelagerte Prüfung sie ablehnen konnte. Ein
/// paralleler Austausch der Quelle konnte damit den temporären Datenträger
/// füllen (Review-Fund 2026-08-17).
///
/// Deshalb hier: die Quelle GENAU EINMAL öffnen, denselben Deskriptor mit
/// `fstat` prüfen und höchstens das erlaubte Bytebudget in eine exklusiv
/// erzeugte Zieldatei streamen. Ein `O_EXCL`-Ziel schließt außerdem aus, dass
/// eine bereits vorhandene Datei oder ein untergeschobener Symlink beschrieben
/// wird.
enum VerifiedFileStaging {
    struct StagingError: LocalizedError {
        /// Woran es lag. Der Aufrufer meldet einen Mangel der QUELLE als
        /// ungültige Eingabe, ein Problem beim Schreiben dagegen als
        /// Dateisystemfehler — das sind für den Nutzer zwei verschiedene
        /// Geschichten.
        enum Kind {
            case source
            case destination
        }

        let kind: Kind
        let reason: String

        init(_ kind: Kind, _ reason: String) {
            self.kind = kind
            self.reason = reason
        }

        var errorDescription: String? { reason }
    }

    /// 256 KiB je Lesevorgang: groß genug für Durchsatz, klein genug, dass der
    /// Speicherbedarf unabhängig von der Dateigröße konstant bleibt.
    private static let chunkSize = 262_144

    /// Streamt höchstens `maximumBytes` aus `sourceURL` nach `destinationURL`.
    ///
    /// Wirft, wenn die Quelle keine reguläre Datei ist, wenn sie das Budget
    /// überschreitet — auch dann, wenn sie erst während des Kopierens wächst —
    /// oder wenn das Ziel schon existiert. Bei jedem Fehler bleibt keine
    /// halbfertige Zieldatei zurück.
    @discardableResult
    static func stage(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int,
        describedAs subject: String
    ) throws -> Int {
        let sourceDescriptor = open(sourceURL.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw StagingError(.source, "\(subject) could not be opened: \(String(cString: strerror(errno)))")
        }
        defer { close(sourceDescriptor) }

        // fstat auf DEMSELBEN Deskriptor: Diese Auskunft gehört garantiert zu
        // den Bytes, die gleich gelesen werden — anders als eine Abfrage über
        // den Pfad, der inzwischen auf etwas anderes zeigen kann.
        var info = stat()
        guard fstat(sourceDescriptor, &info) == 0 else {
            throw StagingError(.source, "\(subject) could not be inspected")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw StagingError(.source, "\(subject) is not a regular file")
        }
        guard info.st_size <= Int64(maximumBytes) else {
            throw StagingError(.source, "\(subject) exceeds the supported size limit")
        }

        let destinationDescriptor = open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            0o600
        )
        guard destinationDescriptor >= 0 else {
            throw StagingError(.destination, "the staging file could not be created")
        }
        var succeeded = false
        defer {
            close(destinationDescriptor)
            if !succeeded {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        var copiedBytes = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let readBytes = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(sourceDescriptor, base, chunkSize)
            }
            if readBytes == 0 { break }
            guard readBytes > 0 else {
                if errno == EINTR { continue }
                throw StagingError(.source, "\(subject) could not be read")
            }
            copiedBytes += readBytes
            // Die Prüfung steht VOR dem Schreiben: Eine Quelle, die während des
            // Kopierens wächst, darf das Budget nicht überziehen.
            guard copiedBytes <= maximumBytes else {
                throw StagingError(.source, "\(subject) exceeds the supported size limit")
            }
            var written = 0
            while written < readBytes {
                let chunk = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return write(destinationDescriptor, base + written, readBytes - written)
                }
                guard chunk > 0 else {
                    if chunk < 0, errno == EINTR { continue }
                    throw StagingError(.destination, "the staging file could not be written")
                }
                written += chunk
            }
        }

        succeeded = true
        return copiedBytes
    }
}
