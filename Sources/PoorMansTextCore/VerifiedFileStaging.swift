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
/// `fstat` prüfen und höchstens das erlaubte Bytebudget lesen. Beim Staging
/// schreibt der Lauf in eine exklusiv erzeugte Zieldatei; ein `O_EXCL`-Ziel
/// schließt aus, dass eine bereits vorhandene Datei oder ein untergeschobener
/// Symlink beschrieben wird.
///
/// Nur das ZIEL wird mit `O_NOFOLLOW` geöffnet. Für die QUELLE wäre dasselbe
/// Flag verfehlt: Es schützt nichts, weil der Deskriptor nach dem Öffnen
/// ohnehin fest an das geöffnete Objekt gebunden ist, lehnte aber einen
/// Symlink auf ein völlig gültiges Dokument ab — ein Weg, auf dem Nutzer ihre
/// Dateien üblicherweise ordnen.
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
        describedAs subject: String,
        followSourceSymlink: Bool = true
    ) throws -> Int {
        try withVerifiedSource(
            at: sourceURL,
            maximumBytes: maximumBytes,
            describedAs: subject,
            followSourceSymlink: followSourceSymlink
        ) { source, _ in
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

            let copiedBytes = try source.readChunks(
                maximumBytes: maximumBytes,
                chunkSize: chunkSize,
                budgetExceeded: {
                    StagingError(.source, "\(subject) exceeds the supported size limit")
                }
            ) { chunk in
                guard var position = chunk.baseAddress else { return true }
                var remaining = chunk.count
                while remaining > 0 {
                    let written = write(destinationDescriptor, position, remaining)
                    guard written > 0 else {
                        if written < 0, errno == EINTR { continue }
                        throw StagingError(.destination, "the staging file could not be written")
                    }
                    position += written
                    remaining -= written
                }
                return true
            }

            succeeded = true
            return copiedBytes
        }
    }

    /// Legt eine private, begrenzte Arbeitskopie an und entfernt sie nach dem
    /// Aufruf wieder. Erkennungsadapter verwenden diesen Weg, wenn ein
    /// Fremdframework wie PDFKit oder `textutil` nur einen Pfad akzeptiert:
    /// Das Framework sieht dann ausschließlich die bereits geprüften Bytes.
    static func withTemporaryCopy<T>(
        of sourceURL: URL,
        maximumBytes: Int,
        describedAs subject: String,
        fileExtension: String,
        body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            ".poormans-text-inspection-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StagingError(.destination, "the private inspection directory could not be created")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let filename = fileExtension.isEmpty ? "source" : "source.\(fileExtension)"
        let copy = root.appendingPathComponent(filename)
        try stage(
            from: sourceURL,
            to: copy,
            maximumBytes: maximumBytes,
            describedAs: subject
        )
        return try body(copy)
    }

    /// Liest höchstens `maximumBytes` aus `sourceURL` in den Speicher — ohne
    /// die Datei abzubilden.
    ///
    /// Für FREMDE Quellen ist das der einzige sichere Weg. `Data(contentsOf:
    /// options: [.mappedIfSafe])` bildet die Datei ab, und `MAP_PRIVATE` schützt
    /// nur vor fremden SCHREIBVORGÄNGEN, nicht vor dem KÜRZEN desselben
    /// Inodes: Ersetzt ein Abgleichdienst die Datei während der Erkennung,
    /// endet jeder Zugriff hinter dem neuen Dateiende mit SIGBUS, und kein
    /// Swift-`catch` fängt das ab. Der ZIP-Leser trennt genau deshalb schon
    /// zwischen fremdem Original und eigener Arbeitskopie; die XLS-Erkennung
    /// bildete dagegen bis 2026-08-25 fremde Dateien bis 1 GiB ab
    /// (Review-Fund 2026-08-25).
    static func contents(
        of sourceURL: URL,
        maximumBytes: Int,
        describedAs subject: String
    ) throws -> Data {
        try withVerifiedSource(
            at: sourceURL,
            maximumBytes: maximumBytes,
            describedAs: subject
        ) { source, size in
            var contents = Data()
            contents.reserveCapacity(Int(size))
            _ = try source.readChunks(
                maximumBytes: maximumBytes,
                chunkSize: chunkSize,
                budgetExceeded: {
                    StagingError(.source, "\(subject) exceeds the supported size limit")
                }
            ) { chunk in
                contents.append(contentsOf: chunk)
                return true
            }
            return contents
        }
    }

    /// Liest höchstens `prefixBytes` vom Anfang einer geprüften Quelle.
    ///
    /// Für eine Signaturprüfung ist das der billige Weg: Ohne diese Grenze
    /// müsste die Erkennung eine bis zu `maximumBytes` große fremde Datei
    /// vollständig in den Speicher lesen, nur um an ihren ersten acht Bytes zu
    /// erkennen, dass sie gar nicht zum Format gehört.
    static func prefix(
        of sourceURL: URL,
        maximumBytes: Int,
        prefixBytes: Int,
        describedAs subject: String
    ) throws -> Data {
        try withVerifiedSource(
            at: sourceURL,
            maximumBytes: maximumBytes,
            describedAs: subject
        ) { source, _ in
            var contents = Data()
            contents.reserveCapacity(prefixBytes)
            _ = try source.readChunks(
                maximumBytes: maximumBytes,
                chunkSize: chunkSize,
                budgetExceeded: {
                    StagingError(.source, "\(subject) exceeds the supported size limit")
                }
            ) { chunk in
                let missing = prefixBytes - contents.count
                contents.append(contentsOf: chunk.prefix(missing))
                return contents.count < prefixBytes
            }
            return contents
        }
    }

    /// Öffnet die Quelle über `VerifiedFile` und prüft zusätzlich, was für ALLE
    /// Wege dieses Typs gilt: reguläre Datei und Größenbudget. Erst danach
    /// bekommt `body` den geprüften Deskriptor.
    private static func withVerifiedSource<T>(
        at sourceURL: URL,
        maximumBytes: Int,
        describedAs subject: String,
        followSourceSymlink: Bool = true,
        body: (_ file: VerifiedFile, _ size: Int64) throws -> T
    ) throws -> T {
        let openBody: (VerifiedFile) throws -> T = { file in
            guard file.isRegularFile else {
                throw StagingError(.source, "\(subject) is not a regular file")
            }
            guard file.info.st_size <= Int64(maximumBytes) else {
                throw StagingError(.source, "\(subject) exceeds the supported size limit")
            }
            return try body(file, file.info.st_size)
        }
        if followSourceSymlink {
            return try VerifiedFile.open(
                at: sourceURL,
                failure: { failure(subject, $0) },
                body: openBody
            )
        }
        return try VerifiedFile.openWithoutFollowing(
            at: sourceURL,
            failure: { failure(subject, $0) },
            body: openBody
        )
    }

    /// Die Fehlertexte dieses Typs. `VerifiedFile` kennt nur den Anlass; der
    /// Betreff („the package", „the XLS source") gehört dem Aufrufer.
    private static func failure(_ subject: String, _ reason: VerifiedFile.Failure) -> Error {
        switch reason {
        case .couldNotOpen(let detail):
            StagingError(.source, "\(subject) could not be opened: \(detail)")
        case .couldNotInspect:
            StagingError(.source, "\(subject) could not be inspected")
        case .couldNotRead:
            StagingError(.source, "\(subject) could not be read")
        }
    }
}
