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
        describedAs subject: String
    ) throws -> Int {
        try withVerifiedSource(
            at: sourceURL,
            maximumBytes: maximumBytes,
            describedAs: subject
        ) { sourceDescriptor, _ in
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

            let copiedBytes = try readVerified(
                from: sourceDescriptor,
                maximumBytes: maximumBytes,
                describedAs: subject
            ) { chunk in
                guard var position = chunk.baseAddress else { return }
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
            }

            succeeded = true
            return copiedBytes
        }
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
        ) { descriptor, size in
            var contents = Data()
            contents.reserveCapacity(Int(size))
            _ = try readVerified(
                from: descriptor,
                maximumBytes: maximumBytes,
                describedAs: subject
            ) { chunk in
                contents.append(contentsOf: chunk)
            }
            return contents
        }
    }

    /// Öffnet die Quelle GENAU EINMAL, prüft am selben Deskriptor und übergibt
    /// ihn samt gemeldeter Größe an `body`. Beide öffentlichen Wege — Kopie in
    /// den Arbeitsordner und Lesen in den Speicher — teilen sich diese Prüfung,
    /// damit es für „reguläre Datei" und „Budget" nur eine Fassung gibt.
    ///
    /// `fstat` fragt DENSELBEN Deskriptor: Diese Auskunft gehört garantiert zu
    /// den Bytes, die gleich gelesen werden — anders als eine Abfrage über den
    /// Pfad, der inzwischen auf etwas anderes zeigen kann.
    ///
    /// `O_NONBLOCK` ist keine Optimierung, sondern der Schutz vor dem
    /// Aufhängen: Ein `open` auf eine FIFO ohne Schreiber kehrt sonst NIE
    /// zurück, und dann steht die ganze Umwandlung ohne Zeitgrenze. Mit dem
    /// Flag kommt der Deskriptor sofort, `fstat` sieht `S_IFIFO` und lehnt die
    /// Quelle ab (Review-Fund 2026-08-19). Für die reguläre Datei, die als
    /// Einzige übrig bleibt, hat das Flag keine Wirkung: Ihre Leseaufrufe
    /// liefern unverändert vollständige Blöcke.
    private static func withVerifiedSource<T>(
        at sourceURL: URL,
        maximumBytes: Int,
        describedAs subject: String,
        body: (_ descriptor: Int32, _ size: Int64) throws -> T
    ) throws -> T {
        let descriptor = open(sourceURL.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw StagingError(.source, "\(subject) could not be opened: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw StagingError(.source, "\(subject) could not be inspected")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw StagingError(.source, "\(subject) is not a regular file")
        }
        guard info.st_size <= Int64(maximumBytes) else {
            throw StagingError(.source, "\(subject) exceeds the supported size limit")
        }

        return try body(descriptor, info.st_size)
    }

    /// Liest den Deskriptor blockweise und reicht jeden gelesenen Block an
    /// `consume` weiter. Rückgabe ist die Gesamtzahl gelesener Bytes.
    ///
    /// Die Budgetprüfung steht VOR dem Übernehmen: Eine Quelle, die während des
    /// Lesens wächst, darf das Budget weder auf der Platte noch im Speicher
    /// überziehen — deshalb entscheidet nicht die anfangs gemeldete Größe,
    /// sondern die tatsächlich gelesene Menge.
    private static func readVerified(
        from descriptor: Int32,
        maximumBytes: Int,
        describedAs subject: String,
        consume: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> Int {
        var readTotal = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let readBytes = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(descriptor, base, chunkSize)
            }
            if readBytes == 0 { break }
            guard readBytes > 0 else {
                if errno == EINTR { continue }
                throw StagingError(.source, "\(subject) could not be read")
            }
            readTotal += readBytes
            guard readTotal <= maximumBytes else {
                throw StagingError(.source, "\(subject) exceeds the supported size limit")
            }
            try buffer.withUnsafeBytes { raw in
                try consume(UnsafeRawBufferPointer(rebasing: raw[0..<readBytes]))
            }
        }
        return readTotal
    }
}
