import Foundation
import zlib

struct ZIPPackageContents {
    let entryNames: Set<String>
    let entries: [String: Data]
}

/// Prüft ZIP-Struktur, Pfade, Größen und Prüfsummen ohne Formatwissen.
/// Fremde Quellen werden über einen Deskriptor gelesen; nur selbst erzeugte
/// Arbeitskopien dürfen per mmap im Speicher liegen.
enum ZIPArchiveInspector {
    /// Stellt ausgewählte Paketdateien für andere native Adapter bereit. Schon
    /// das Öffnen des Archivs prüft Namen, Größenbudgets, Verschlüsselung,
    /// Kompressionsarten und Symlinks; die Konvertierung ruft diese Funktion auf
    /// einer zuvor vollständig verifizierten Arbeitskopie auf.
    static func packageContents(at inputURL: URL, entryNames: [String]) throws -> ZIPPackageContents {
        try inspectionSnapshot(at: inputURL).contents(entryNames: entryNames)
    }

    /// Die Erkennung liest begrenzte Bereiche über den geprüften Deskriptor. Namen,
    /// Archivbudgets und jeder gelesene Eintrag werden wie bisher geprüft;
    /// die Vollprüfung aller Medien folgt erst vor der Konvertierung.
    static func inspectionSnapshot(at inputURL: URL) throws -> some ZIPPackageReading {
        ZIPInspectionSnapshot(archive: try Archive(url: inputURL))
    }

    /// Der Reader darf nur aus einem selbst angelegten, vollständig geprüften
    /// Snapshot entstehen. Der Aufrufer besitzt den privaten Arbeitsordner.
    static func openVerifiedPackage(from inputURL: URL, into directory: URL, named name: String) throws -> ZIPPackageReader {
        let stagedURL = try stageCopy(from: inputURL, into: directory, named: name)
        let archive = try Archive(url: stagedURL, mapsPrivateCopy: true)
        try archive.verifyEntryContents()
        return ZIPPackageReader(url: stagedURL, archive: archive)
    }

    /// Kurzlebiger Reader für Erkennung und eigenständige Parseraufrufe.
    /// Auch hier wird nie ein fremdes Original per mmap abgebildet.
    static func withVerifiedReader<T>(at inputURL: URL, _ body: (ZIPPackageReader) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PoorMansTextPackage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try openVerifiedPackage(from: inputURL, into: directory, named: "source.zip")
        return try body(reader)
    }

    /// Kopiert das Paket unveränderlich in den privaten Arbeitsbereich und prüft
    /// genau diese Kopie vollständig durch.
    ///
    /// Zwei Gründe für die Kopie: Der geprüfte Originalpfad kann zwischen Prüfung
    /// und Pandoc-Lauf ausgetauscht werden (Time-of-check-to-time-of-use), und nur
    /// eine Kopie im eigenen Arbeitsordner bleibt während der Umwandlung stabil.
    /// Die Prüfung entpackt jeden Eintrag streamend und vergleicht dabei
    /// tatsächliche Größe und Prüfsumme mit den Angaben im ZIP-Verzeichnis — ohne
    /// das zählt das Entpackbudget nur die *deklarierten* Größen, und ein
    /// präparierter Medieneintrag könnte beim Pandoc-Lauf beliebig groß werden.
    static func stageVerifiedPackage(
        from inputURL: URL,
        into directory: URL,
        named name: String
    ) throws -> URL {
        try openVerifiedPackage(from: inputURL, into: directory, named: name).url
    }

    private static func stageCopy(from inputURL: URL, into directory: URL, named name: String) throws -> URL {
        // Öffnen, prüfen und begrenzt streamen in einem Zug — den Pfad erst zu
        // prüfen und danach zu kopieren ließ einen parallelen Austausch der
        // Quelle die Größengrenze umgehen (Review-Fund 2026-08-17).
        let stagedURL = directory.appendingPathComponent(name)
        do {
            try VerifiedFileStaging.stage(
                from: inputURL,
                to: stagedURL,
                maximumBytes: Limits.maximumArchiveSize,
                describedAs: "the package"
            )
        } catch let error as VerifiedFileStaging.StagingError where error.kind == .source {
            throw ArchiveError(error.reason)
        } catch let error as VerifiedFileStaging.StagingError {
            throw ConversionError.fileSystemFailure(error.reason)
        } catch {
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }

        return stagedURL
    }

    /// Blickt in die ersten vier Bytes und sagt, ob dort eine ZIP-Signatur steht.
    ///
    /// Geöffnet und geprüft wird über `withOpenFile`; alles außer einer
    /// regulären Datei ist hier schlicht kein ZIP-Paket und keine Störung.
    static func looksLikeZIP(at inputURL: URL) throws -> Bool {
        do {
            return try VerifiedFile.open(at: inputURL, failure: packageFailure) { package in
                guard package.isRegularFile else {
                    return false
                }

                var signature = [UInt8](repeating: 0, count: 4)
                let readBytes = try signature.withUnsafeMutableBytes { raw in
                    try package.readFully(into: raw)
                }
                guard readBytes == signature.count else {
                    return false               // die Datei ist kürzer als vier Bytes
                }
                return signature == [0x50, 0x4B, 0x03, 0x04]
                    || signature == [0x50, 0x4B, 0x05, 0x06]
                    || signature == [0x50, 0x4B, 0x07, 0x08]
            }
        } catch {
            // Ein unlesbares Original ist kein kaputtes Dokumentformat. Die
            // CLI muss den Zugriff als Ein-/Ausgabefehler (Exit 74) melden.
            throw ConversionError.fileSystemFailure(error.localizedDescription)
        }
    }

    fileprivate struct Archive {
        let data: ArchiveBytes
        let entries: [Entry]
        private let entriesByName: [String: Entry]
        private let centralOffset: Int

        /// - Parameter mapsPrivateCopy: nur `true` für eine Datei, die dieser
        ///   Prozess gerade selbst in seinen Arbeitsordner geschrieben hat.
        ///   Fremde Originale werden gelesen statt abgebildet.
        init(url: URL, mapsPrivateCopy: Bool = false) throws {
            // Prüfung und Bytes gehören zu EINEM geöffneten Objekt. Ein
            // Verweis auf ein gültiges Paket bleibt dabei erlaubt: `open` folgt
            // ihm, und `fstat` beschreibt danach die Datei dahinter statt den
            // Verweis selbst.
            data = try ArchiveBytes(
                url: url,
                mapsPrivateCopy: mapsPrivateCopy
            )
            guard let endOffset = try Self.endOfCentralDirectory(in: data) else {
                throw ArchiveError("the ZIP central directory is missing")
            }
            guard try data.uint16(at: endOffset + 4) == 0,
                  try data.uint16(at: endOffset + 6) == 0 else {
                throw ArchiveError("multi-disk ZIP packages are not supported")
            }

            let entryCount = Int(try data.uint16(at: endOffset + 10))
            let centralSize = Int(try data.uint32(at: endOffset + 12))
            let centralOffset = Int(try data.uint32(at: endOffset + 16))
            self.centralOffset = centralOffset
            // Die Eintragszahl steht zweimal im Schlussblock: einmal für diesen
            // Datenträger, einmal insgesamt. Nur die Gesamtzahl wurde gelesen —
            // ein Verbraucher, der die andere nimmt, sah einen anderen
            // Eintragssatz als diese Prüfung (Review-Fund 2026-09-10). Alle 600
            // geprüften echten Archive tragen dort denselben Wert.
            guard Int(try data.uint16(at: endOffset + 8)) == entryCount else {
                throw ArchiveError("the ZIP end record disagrees about its entry count")
            }
            guard entryCount != Int(UInt16.max),
                  centralSize != Int(UInt32.max),
                  centralOffset != Int(UInt32.max) else {
                throw ArchiveError("ZIP64 packages are not supported")
            }
            // ZIP64 wurde bisher allein an den Sentinel-Werten erkannt. Liegt
            // direkt vor dem Schlussblock ein ZIP64-Locator, ersetzen manche
            // Entpacker die 32-Bit-Angaben ohne jede Sentinel-Bedingung und
            // lesen damit ein anderes, hier nie geprüftes Verzeichnis. Kein
            // einziges der 600 geprüften echten Archive trägt einen Locator.
            if endOffset >= 20, try data.uint32(at: endOffset - 20) == 0x07064B50 {
                throw ArchiveError("ZIP64 packages are not supported")
            }
            guard entryCount <= Limits.maximumEntryCount else {
                throw ArchiveError("the package contains too many ZIP entries")
            }
            guard centralOffset >= 0,
                  centralSize >= 0,
                  centralOffset + centralSize <= endOffset else {
                throw ArchiveError("the ZIP central directory is invalid")
            }

            var parsedEntries = [Entry]()
            parsedEntries.reserveCapacity(entryCount)
            // Zwei getrennte Sichten, zwei getrennte Kollisionsprüfungen: Ein
            // Verbraucher liest entweder den Namen mit Unicode-Extrafeld oder den
            // aus den Rohbytes. Jede Sicht für sich muss eindeutig sein; ein
            // Treffer QUER über beide Sichten sagt dagegen nichts, weil kein
            // Verbraucher beide Namen zugleich sieht.
            var names = Set<String>()
            var rawNames = Set<String>()
            var totalUncompressedSize = 0
            var offset = try Self.directoryStart(in: data, at: centralOffset, limit: centralOffset + centralSize)

            for _ in 0..<entryCount {
                try ConversionExecution.check()
                guard try data.uint32(at: offset) == 0x02014B50 else {
                    throw ArchiveError("the ZIP central directory contains an invalid entry")
                }
                let flags = try data.uint16(at: offset + 8)
                let method = try data.uint16(at: offset + 10)
                let crc = try data.uint32(at: offset + 16)
                let compressedSize = Int(try data.uint32(at: offset + 20))
                let uncompressedSize = Int(try data.uint32(at: offset + 24))
                let nameLength = Int(try data.uint16(at: offset + 28))
                let extraLength = Int(try data.uint16(at: offset + 30))
                let commentLength = Int(try data.uint16(at: offset + 32))
                let externalAttributes = try data.uint32(at: offset + 38)
                let localHeaderOffset = Int(try data.uint32(at: offset + 42))
                let entryEnd = offset + 46 + nameLength + extraLength + commentLength

                guard compressedSize != Int(UInt32.max),
                      uncompressedSize != Int(UInt32.max),
                      localHeaderOffset != Int(UInt32.max) else {
                    throw ArchiveError("ZIP64 entries are not supported")
                }
                guard entryEnd <= centralOffset + centralSize,
                      nameLength > 0 else {
                    throw ArchiveError("a ZIP entry has an invalid length")
                }
                guard flags & 0x0001 == 0 else {
                    throw ArchiveError("encrypted ZIP entries are not supported")
                }
                guard method == 0 || method == 8 else {
                    throw ArchiveError("a ZIP entry uses an unsupported compression method")
                }

                let rawName = try data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
                let extraField = try data.subdata(
                    in: (offset + 46 + nameLength)..<(offset + 46 + nameLength + extraLength)
                )
                guard !rawName.contains(0) else {
                    throw ArchiveError("a ZIP entry name is not readable")
                }
                let entryNames = try Self.entryNames(
                    rawName: rawName,
                    flags: flags,
                    extraField: extraField
                )
                let name = entryNames.effective
                // BEIDE Namen müssen sicher sein, nicht nur der bevorzugte: Ein
                // Verbraucher, der das Unicode-Extrafeld nicht liest, entpackt
                // nach dem Rohnamen, und der wurde vorher nie geprüft.
                try Self.validateEntryName(name)
                try Self.validateEntryName(entryNames.rawDecoded)
                // Und beide müssen dasselbe MEINEN. Der abschließende Slash
                // entscheidet über „Verzeichnis oder Datei", und ein Eintrag, der
                // nur über den Unicode-Namen als Verzeichnis auftritt, überspränge
                // damit die Größen- und CRC-Prüfung in `verifyEntryContents` —
                // während der Verbraucher die ungeprüfte Nutzlast unter dem
                // Rohnamen bekommt (Review-Fund 2026-08-19).
                guard name.hasSuffix("/") == entryNames.rawDecoded.hasSuffix("/") else {
                    throw ArchiveError(
                        "a ZIP entry and its Unicode path field disagree about being a directory"
                    )
                }
                // Beim Entpacken zählt der Name, den das Dateisystem sieht: APFS
                // ist standardmäßig nicht zwischen Groß- und Kleinschreibung
                // unterscheidend, deshalb würden `word/media/a.png` und
                // `word/media/A.png` dieselbe Datei sein und ein Eintrag den
                // anderen still überschreiben. Der abschließende Slash fällt
                // dabei weg, damit auch der Verzeichniseintrag `x/` mit der
                // Datei `x` kollidiert. Unicode-Normalisierung (etwa "ä" als ein
                // Zeichen gegen "a" plus Trema) fängt der Swift-Vergleich von
                // Zeichenketten bereits selbst ab.
                let collisionKey = Self.logicalName(of: name).folding(
                    options: [.caseInsensitive],
                    locale: nil
                )
                guard names.insert(collisionKey).inserted else {
                    throw ArchiveError("the ZIP package contains a duplicate entry: \(name)")
                }
                let rawCollisionKey = Self.logicalName(of: entryNames.rawDecoded).folding(
                    options: [.caseInsensitive],
                    locale: nil
                )
                guard rawNames.insert(rawCollisionKey).inserted else {
                    throw ArchiveError(
                        "the ZIP package contains a duplicate entry: \(entryNames.rawDecoded)"
                    )
                }

                // Das Symlink-Muster im oberen Attributwort zählt unabhängig
                // davon, welches Host-System der Erzeuger einträgt. Vorher war
                // die Prüfung an `hostSystem == 3` (Unix) gebunden; derselbe
                // Eintrag unter „OS X (Darwin)" (19) oder MS-DOS (0) kam damit
                // durch das Gate. Ein Fehlalarm entsteht dadurch nicht: Word,
                // LibreOffice, Pandoc und textutil schreiben hostSystem 0 und
                // lassen das obere Wort leer, wie die Fixtures dieses Repos
                // zeigen.
                let unixMode = externalAttributes >> 16
                if unixMode & 0xF000 == 0xA000 {
                    throw ArchiveError("symbolic links are not allowed in document packages")
                }

                // `verifyEntryContents` überspringt Verzeichnisse. Damit dieses
                // Übergehen folgenlos bleibt, darf ein Verzeichniseintrag gar
                // keine Nutzlast deklarieren — so schreibt es auch jedes echte
                // Werkzeug: die Verzeichniseinträge der ODT-Fixtures dieses Repos
                // stehen alle auf 0.
                if name.hasSuffix("/"), compressedSize != 0 || uncompressedSize != 0 {
                    throw ArchiveError("a ZIP directory entry declares content: \(name)")
                }

                totalUncompressedSize += uncompressedSize
                guard totalUncompressedSize <= Limits.maximumUncompressedSize else {
                    throw ArchiveError("the ZIP package expands beyond the supported size limit")
                }

                parsedEntries.append(
                    Entry(
                        name: name,
                        rawName: rawName,
                        flags: flags,
                        method: method,
                        crc: crc,
                        compressedSize: compressedSize,
                        uncompressedSize: uncompressedSize,
                        localHeaderOffset: localHeaderOffset,
                        isDirectory: name.hasSuffix("/")
                    )
                )
                offset = entryEnd
            }

            let signatureOffset = offset
            offset = try Self.afterSignature(in: data, at: offset, limit: centralOffset + centralSize)
            guard offset == centralOffset + centralSize else {
                throw ArchiveError("the ZIP central directory size is inconsistent")
            }
            let afterDirectory = try Self.afterSignature(in: data, at: offset, limit: endOffset)
            guard signatureOffset == offset || afterDirectory == offset else {
                throw ArchiveError("the ZIP central directory has more than one digital signature record")
            }
            guard afterDirectory == endOffset else {
                throw ArchiveError("the ZIP contains an unexplained gap after its central directory")
            }
            entries = parsedEntries
            // `uniqueKeysWithValues` würde bei zwei gleichnamigen Einträgen
            // nicht werfen, sondern den Prozess beenden. Die Kollisionsprüfung
            // oben schließt das heute aus — aber ein Absturz darf nicht die
            // letzte Sicherung eines fremden Archivs sein, deshalb gewinnt hier
            // schlicht der erste Eintrag (Review-Fund 2026-09-10).
            entriesByName = Dictionary(
                parsedEntries.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        func string(named name: String) throws -> String {
            String(decoding: try data(named: name), as: UTF8.self)
        }

        func data(named name: String) throws -> Data {
            guard let entry = entriesByName[name] else {
                throw ArchiveError("the document package is missing \(name)")
            }
            return try data(for: entry)
        }

        func data(for entry: Entry) throws -> Data {
            guard entry.uncompressedSize <= Limits.maximumMetadataEntrySize else {
                throw ArchiveError("the package metadata entry \(entry.name) is too large")
            }
            guard entry.compressedSize <= Limits.maximumMetadataEntrySize else {
                throw ArchiveError("the compressed package metadata entry \(entry.name) is too large")
            }
            if entry.method == 0, entry.compressedSize != entry.uncompressedSize {
                // Vor dem Slice prüfen: Ein gespeicherter Eintrag mit wenigen
                // deklarierten Ausgabebytes durfte sonst zuerst fast das ganze
                // Archiv als `subdata` kopieren.
                throw ArchiveError(
                    "the stored size of \(entry.name) does not match its declared size"
                )
            }
            try validateLayout()
            let contentRange = try contentRange(for: entry)

            let result: Data
            switch entry.method {
            case 0:
                result = Data(try data.bytes(in: contentRange))
            case 8:
                result = try inflate(
                    try data.bytes(in: contentRange),
                    expectedSize: entry.uncompressedSize,
                    entryName: entry.name
                )
            default:
                throw ArchiveError("the ZIP compression method is unsupported")
            }

            guard result.count == entry.uncompressedSize else {
                throw ArchiveError("the uncompressed size of \(entry.name) is inconsistent")
            }
            try ZIPArchiveInspector.verifyChecksum(
                of: result,
                expected: entry.crc,
                entryName: entry.name
            )
            return result
        }

        /// Prüft JEDEN Eintrag gegen seinen Verzeichniseintrag: tatsächliche
        /// entpackte Größe und CRC-32. Erst danach ist das in `init` geprüfte
        /// Entpackbudget wirklich belastbar, denn dort werden nur die vom Archiv
        /// selbst deklarierten Größen addiert.
        ///
        /// Der Inhalt wird dabei absichtlich nicht behalten: Jeder Eintrag läuft
        /// in Blöcken durch einen festen kleinen Puffer, und sobald mehr Bytes
        /// entstehen als deklariert, bricht die Prüfung sofort ab. Ein präparierter
        /// Eintrag kann so weder Speicher noch Zeit über sein deklariertes Maß
        /// hinaus verbrauchen.
        ///
        /// Die private Abbildung liefert einen Ausschnitt auf denselben Speicher.
        /// `subdata(in:)` würde stattdessen jeden Eintrag zusätzlich kopieren —
        /// bei einem zulässigen Archiv von bis zu 1 GiB wäre die angeblich
        /// streamende Prüfung dann der größte Speicherverbraucher überhaupt.
        func verifyEntryContents() throws {
            try validateLayout()
            for entry in entries {
                try ConversionExecution.check()
                // Auch Verzeichniseinträge durchlaufen die Kopfprüfung. Sonst
                // ist `contentRange` — die EINZIGE Stelle, die einen lokalen
                // Header überhaupt ansieht — für sie nie aufgerufen worden: Ihr
                // lokaler Header durfte einen anderen Namen und eine beliebige
                // Nutzlast deklarieren, die ein streamender Verbraucher sieht
                // und diese Prüfung nie (Review-Fund 2026-09-10). Alle 2517
                // Verzeichniseinträge der geprüften 600 echten Archive tragen
                // einen lokalen Header.
                let contentRange = try contentRange(for: entry)
                guard !entry.isDirectory else {
                    continue
                }
                switch entry.method {
                case 0:
                    guard entry.compressedSize == entry.uncompressedSize else {
                        throw ArchiveError(
                            "the stored size of \(entry.name) does not match its declared size"
                        )
                    }
                    try ZIPArchiveInspector.verifyChecksum(
                        of: try data.bytes(in: contentRange),
                        expected: entry.crc,
                        entryName: entry.name
                    )
                case 8:
                    try ZIPArchiveInspector.verifyDeflated(
                        try data.bytes(in: contentRange),
                        expectedSize: entry.uncompressedSize,
                        expectedChecksum: entry.crc,
                        entryName: entry.name
                    )
                default:
                    throw ArchiveError("the ZIP compression method is unsupported")
                }
            }
        }

        /// Der Bytebereich des Eintragsinhalts, nachdem der lokale Header gegen
        /// den Verzeichniseintrag geprüft wurde.
        private func contentRange(for entry: Entry) throws -> Range<Int> {
            let offset = entry.localHeaderOffset
            guard try data.uint32(at: offset) == 0x04034B50 else {
                throw ArchiveError("the local ZIP header for \(entry.name) is invalid")
            }
            let localFlags = try data.uint16(at: offset + 6)
            let localMethod = try data.uint16(at: offset + 8)
            let localChecksum = try data.uint32(at: offset + 14)
            let localCompressedSize = Int(try data.uint32(at: offset + 18))
            let localUncompressedSize = Int(try data.uint32(at: offset + 22))
            let nameLength = Int(try data.uint16(at: offset + 26))
            let extraLength = Int(try data.uint16(at: offset + 28))
            let contentStart = offset + 30 + nameLength + extraLength
            let contentEnd = contentStart + entry.compressedSize
            guard localFlags == entry.flags,
                  localMethod == entry.method,
                  entry.compressedSize >= 0,
                  contentEnd <= centralOffset,
                  try data.subdata(in: (offset + 30)..<(offset + 30 + nameLength))
                    == entry.rawName else {
                throw ArchiveError("the local ZIP entry for \(entry.name) is inconsistent")
            }
            // Prüfsumme und beide Größen standen bisher als einzige Felder des
            // lokalen Headers ungeprüft da. Der geprüfte Bytebereich stammt aus
            // dem Verzeichniseintrag; ein Verbraucher, der stattdessen die
            // lokale Längenangabe liest — so arbeiten streamende Entpacker —
            // bekam damit einen Strom, den weder Entpackbudget noch Prüfsumme je
            // gesehen haben (Review-Fund 2026-09-10).
            //
            // Die Regel folgt dem, was echte Erzeuger schreiben, geprüft an 600
            // Archiven mit 134 879 Einträgen: Ohne Datendeskriptor (Bit 3) sind
            // beide Kopien gleich. Mit Bit 3 lässt der Erzeuger die Felder offen,
            // füllt sie aber teils trotzdem — LibreOffice schreibt alle drei als
            // 0, andere tragen die entpackte Größe ein. Deshalb gilt dort je
            // Feld: entweder 0 oder derselbe Wert.
            let allowsDeferredFields = entry.flags & 0x0008 != 0
            let localFields = [localChecksum == entry.crc, localCompressedSize == entry.compressedSize,
                               localUncompressedSize == entry.uncompressedSize]
            let deferredFields = [localChecksum == 0, localCompressedSize == 0, localUncompressedSize == 0]
            for (matches, isDeferred) in zip(localFields, deferredFields)
            where !matches && !(allowsDeferredFields && isDeferred) {
                throw ArchiveError(
                    "the local ZIP header for \(entry.name) declares a different size or checksum"
                )
            }
            // Das Extrafeld steht zweimal im Archiv, und manche Verbraucher lesen
            // den Namen aus dem lokalen Header. Ein eigenes Unicode-Path-Feld dort
            // ergäbe für sie einen anderen Pfad als den hier geprüften, deshalb
            // muss der wirksame Name beider Kopien übereinstimmen. Verglichen wird
            // nur dieses eine Feld: Die übrigen Extrafelder dürfen sich regulär
            // unterscheiden — Info-ZIP schreibt lokal etwa mehr Zeitstempel als
            // zentral.
            let localExtraField = try data.subdata(
                in: (offset + 30 + nameLength)..<(offset + 30 + nameLength + extraLength)
            )
            let localNames = try Self.entryNames(
                rawName: entry.rawName,
                flags: localFlags,
                extraField: localExtraField
            )
            guard localNames.effective == entry.name else {
                throw ArchiveError(
                    "the local ZIP header for \(entry.name) declares a different Unicode path"
                )
            }
            return contentStart..<contentEnd
        }

        private func validateLayout() throws {
            if data.layoutValidated { return }
            var cursor = 0
            let ordered = entries.sorted(by: { $0.localHeaderOffset < $1.localHeaderOffset })
            for (index, entry) in ordered.enumerated() {
                try ConversionExecution.check()
                guard entry.localHeaderOffset == cursor else {
                    throw ArchiveError("the ZIP contains overlapping entries or unexplained data before its central directory")
                }
                cursor = try contentRange(for: entry).upperBound
                if entry.flags & 0x0008 != 0 {
                    let nextHeader = index + 1 < ordered.count ? ordered[index + 1].localHeaderOffset : centralOffset
                    let signed = try data.uint32(at: cursor) == 0x08074B50
                    let possibleFields = signed ? [cursor + 4, cursor] : [cursor]
                    var descriptorEnd: Int?
                    for fields in possibleFields {
                        if fields + 12 == nextHeader,
                           try data.uint32(at: fields) == entry.crc,
                           try data.uint32(at: fields + 4) == UInt32(entry.compressedSize),
                           try data.uint32(at: fields + 8) == UInt32(entry.uncompressedSize) {
                            descriptorEnd = fields + 12
                            break
                        }
                    }
                    if let descriptorEnd { cursor = descriptorEnd }
                    else if cursor != nextHeader {
                        throw ArchiveError("the ZIP data descriptor for \(entry.name) is inconsistent")
                    }
                    // Die bestehende Kompatibilität erlaubt Bit 3 auch ohne
                    // Folge; Größen und CRC stammen dann vom geprüften
                    // Verzeichnis. Dabei darf keine ungeklärte Lücke entstehen.
                }
            }
            guard cursor == centralOffset else {
                throw ArchiveError("the ZIP contains unexplained data before its central directory")
            }
            data.layoutValidated = true
        }

        private static func directoryStart(in source: ArchiveBytes, at offset: Int, limit: Int) throws -> Int {
            if try source.uint32(at: offset) == 0x08064B50 {
                guard offset + 8 <= limit else { throw ArchiveError("the ZIP archive extra data record is truncated") }
                let end = offset + 8 + Int(try source.uint32(at: offset + 4))
                guard end <= limit else { throw ArchiveError("the ZIP archive extra data record is truncated") }
                return end
            }
            return offset
        }

        private static func afterSignature(in source: ArchiveBytes, at offset: Int, limit: Int) throws -> Int {
            guard offset < limit, try source.uint32(at: offset) == 0x05054B50 else { return offset }
            guard offset + 6 <= limit else { throw ArchiveError("the ZIP digital signature record is truncated") }
            let end = offset + 6 + Int(try source.uint16(at: offset + 4))
            guard end <= limit else { throw ArchiveError("the ZIP digital signature record is truncated") }
            return end
        }

        private static func endOfCentralDirectory(in source: ArchiveBytes) throws -> Int? {
            guard source.count >= 22 else { return nil }
            let lowerBound = max(0, source.count - 65_557)
            let tail = Data(try source.bytes(in: lowerBound..<source.count))
            var selected: Int?
            var candidates = [Int]()
            for offset in stride(from: tail.count - 22, through: 0, by: -1) {
                if tail.uint32(at: offset) == 0x06054B50 {
                    candidates.append(lowerBound + offset)
                    if selected == nil, offset + 22 + Int(tail.uint16(at: offset + 20)) == tail.count {
                        selected = lowerBound + offset
                    }
                }
            }
            guard let selected else { return nil }
            let selectedOffset = Int(try source.uint32(at: selected + 16))
            let selectedSize = Int(try source.uint32(at: selected + 12))
            var checkedDirectories = [DirectoryView: Bool]()
            var equivalentDirectories = Set<DirectoryView>()
            var remainingComparisonBytes = Limits.maximumArchiveSize
            var remainingEntries = Limits.maximumEntryCount
            for candidate in candidates where candidate != selected {
                try ConversionExecution.check()
                let offset = Int(try source.uint32(at: candidate + 16))
                let size = Int(try source.uint32(at: candidate + 12))
                let count = Int(try source.uint16(at: candidate + 10))
                guard count <= Limits.maximumEntryCount,
                      try source.uint16(at: candidate + 4) == 0,
                      try source.uint16(at: candidate + 6) == 0,
                      try source.uint16(at: candidate + 8) == UInt16(count),
                      offset + size <= candidate,
                      candidate + 22 + Int(try source.uint16(at: candidate + 20)) <= source.count else { continue }
                let view = DirectoryView(offset: offset, size: size, count: count)
                // Viele Schlussblockmuster dürfen nicht immer wieder dasselbe
                // Verzeichnis ablaufen. Unterschiedliche Kandidaten teilen
                // zusätzlich das vorhandene Eintragsbudget.
                let valid: Bool
                if let previous = checkedDirectories[view] {
                    valid = previous && offset + size <= candidate
                } else {
                    valid = try hasDirectory(in: source, endOffset: candidate, remainingEntries: &remainingEntries)
                    checkedDirectories[view] = valid
                }
                guard valid, !equivalentDirectories.contains(view) else { continue }
                guard size == selectedSize,
                      try source.uint16(at: candidate + 10) == source.uint16(at: selected + 10),
                      try sameBytes(in: source, first: selectedOffset, second: offset, count: size,
                                    remainingBytes: &remainingComparisonBytes) else {
                    throw ArchiveError("the ZIP has conflicting end records and different directory views")
                }
                equivalentDirectories.insert(view)
            }
            return selected
        }

        private struct DirectoryView: Hashable {
            let offset: Int
            let size: Int
            let count: Int
        }

        /// Ein Signaturmuster im Kommentar genügt nicht: Erst eine vollständig
        /// begrenzte Verzeichnisfolge belegt die alternative Entpacker-Sicht.
        private static func hasDirectory(in source: ArchiveBytes, endOffset: Int, remainingEntries: inout Int) throws -> Bool {
            let count = Int(try source.uint16(at: endOffset + 10))
            let size = Int(try source.uint32(at: endOffset + 12))
            let offset = Int(try source.uint32(at: endOffset + 16))
            guard count <= Limits.maximumEntryCount,
                  try source.uint16(at: endOffset + 4) == 0,
                  try source.uint16(at: endOffset + 6) == 0,
                  try source.uint16(at: endOffset + 8) == UInt16(count),
                  offset + size <= endOffset,
                  endOffset + 22 + Int(try source.uint16(at: endOffset + 20)) <= source.count else { return false }
            var cursor = offset
            let limit = offset + size
            if try source.uint32(at: cursor) == 0x08064B50 {
                guard cursor + 8 <= limit else { return false }
                cursor += 8 + Int(try source.uint32(at: cursor + 4))
            }
            for _ in 0..<count {
                try ConversionExecution.check()
                guard remainingEntries > 0 else {
                    throw ArchiveError("the ZIP end-record ambiguity exceeds the supported inspection budget")
                }
                remainingEntries -= 1
                guard cursor + 46 <= limit, try source.uint32(at: cursor) == 0x02014B50 else { return false }
                let nameLength = Int(try source.uint16(at: cursor + 28))
                guard nameLength > 0 else { return false }
                cursor += 46 + nameLength + Int(try source.uint16(at: cursor + 30))
                    + Int(try source.uint16(at: cursor + 32))
                guard cursor <= limit else { return false }
            }
            if cursor < limit, try source.uint32(at: cursor) == 0x05054B50 {
                guard cursor + 6 <= limit else { return false }
                cursor += 6 + Int(try source.uint16(at: cursor + 4))
            }
            return cursor == limit
        }

        private static func sameBytes(in source: ArchiveBytes, first: Int, second: Int, count: Int,
                                      remainingBytes: inout Int) throws -> Bool {
            guard first >= 0, second >= 0, first + count <= source.count, second + count <= source.count else { return false }
            if first == second { return true }
            for offset in stride(from: 0, to: count, by: 65_536) {
                let length = min(65_536, count - offset)
                guard remainingBytes >= length else {
                    throw ArchiveError("the ZIP end-record ambiguity exceeds the supported inspection budget")
                }
                remainingBytes -= length
                if try source.bytes(in: (first + offset)..<(first + offset + length))
                    != source.bytes(in: (second + offset)..<(second + offset + length)) { return false }
            }
            return true
        }

        /// Der Eintragsname genau so, wie ein regelkonformer ZIP-Verbraucher ihn liest.
        ///
        /// Vorher wurde jeder Name erst als UTF-8 und ersatzweise als
        /// ISO-8859-1 gelesen — unabhängig vom General-Purpose-Bit 11. Ein
        /// regelkonformer Name ohne dieses Bit ist aber CP437: Rohbyte `0x80`
        /// heißt dort `Ç`, `0x87` heißt `ç`. Als ISO-8859-1 gelesen wurden
        /// daraus die verschiedenen Steuerzeichen U+0080 und U+0087, und das
        /// Kollisions-Gate unten sah zwei verschiedene Namen, wo ein Entpacker
        /// auf einem case-insensitiven Dateisystem denselben Pfad sieht — ein
        /// Eintrag hätte den anderen still überschrieben
        /// (Review-Fund 2026-08-17).
        private static func entryNames(
            rawName: Data,
            flags: UInt16,
            extraField: Data
        ) throws -> EntryNames {
            let rawDecoded = try Self.rawDecodedName(rawName: rawName, flags: flags)
            // Ein Unicode-Path-Extrafeld hat Vorrang, sobald es zum Rohnamen
            // passt: genau diesen Namen nimmt auch ein regelkonformer Entpacker.
            // Der Rohname bleibt trotzdem erhalten — ein Verbraucher, der das Feld
            // nicht auswertet, arbeitet mit ihm.
            guard let unicodeName = try Self.unicodePathName(in: extraField, rawName: rawName) else {
                return EntryNames(effective: rawDecoded, rawDecoded: rawDecoded)
            }
            return EntryNames(effective: unicodeName, rawDecoded: rawDecoded)
        }

        private static func rawDecodedName(rawName: Data, flags: UInt16) throws -> String {
            if flags & 0x0800 != 0 {
                // Bit 11 gesetzt heißt: der Name IST UTF-8. Ein Rückfall auf
                // eine andere Kodierung wäre hier eine stille Umdeutung.
                guard let name = String(data: rawName, encoding: .utf8) else {
                    throw ArchiveError("a ZIP entry declares a UTF-8 name but is not valid UTF-8")
                }
                return name
            }
            return Self.cp437Name(of: rawName)
        }

        /// Der Name aus einem Unicode-Path-Extrafeld (Header-ID `0x7075`), falls
        /// vorhanden und gültig.
        ///
        /// Das Feld trägt eine CRC-32-Prüfsumme über den Rohnamen. Stimmt sie
        /// nicht, ist das Feld veraltet und der Rohname gilt — so schreibt es
        /// APPNOTE 4.6.9 vor. Ist das Feld selbst kaputt (unbekannte Version
        /// oder ungültiges UTF-8), brechen wir ab, statt einen Namen zu
        /// verwenden, den ein Entpacker anders lesen würde.
        private static func unicodePathName(in extraField: Data, rawName: Data) throws -> String? {
            // `subdata(in:)` liefert eine Data mit startIndex 0 — die Offsets
            // hier sind deshalb wie im übrigen Parser rein 0-basiert.
            var cursor = 0
            // Das GANZE Extrafeld wird durchlaufen. Vorher endete die Suche beim
            // ersten `0x7075`-Feld: Ein veraltetes erstes Feld verdeckte damit
            // ein zweites, gültiges — und dessen Name wurde nie gegen Traversal
            // geprüft, obwohl ein anderer Entpacker genau ihn nehmen kann
            // (Review-Fund 2026-08-20).
            var sawUnicodeField = false
            var unicodeName: String?
            while cursor + 4 <= extraField.count {
                let headerID = extraField.uint16(at: cursor)
                let payloadSize = Int(extraField.uint16(at: cursor + 2))
                let payloadStart = cursor + 4
                guard payloadStart + payloadSize <= extraField.count else {
                    throw ArchiveError("a ZIP entry has a malformed extra field")
                }
                if headerID == 0x7075 {
                    guard !sawUnicodeField else {
                        throw ArchiveError("a ZIP entry has more than one Unicode path field")
                    }
                    sawUnicodeField = true
                    // 1 Byte Version + 4 Byte CRC-32 + UTF-8-Name.
                    guard payloadSize >= 5 else {
                        throw ArchiveError("a ZIP entry has a malformed Unicode path field")
                    }
                    let payload = extraField.subdata(in: payloadStart..<(payloadStart + payloadSize))
                    guard payload[0] == 1 else {
                        throw ArchiveError("a ZIP entry uses an unsupported Unicode path version")
                    }
                    if payload.uint32(at: 1) == Self.crc32(of: rawName) {
                        let nameBytes = payload.subdata(in: 5..<payload.count)
                        guard !nameBytes.isEmpty,
                              !nameBytes.contains(0),
                              let name = String(data: nameBytes, encoding: .utf8) else {
                            throw ArchiveError("a ZIP entry has an unreadable Unicode path field")
                        }
                        unicodeName = name
                    }
                    // Passt die Prüfsumme nicht, ist das Feld veraltet und der
                    // Rohname gilt. Weitergelesen wird trotzdem, damit ein
                    // zweites solches Feld auffällt.
                }
                cursor = payloadStart + payloadSize
            }
            // Ein Extrafeld ist eine lückenlose Folge aus Kennung, Länge und
            // Nutzlast. Bleiben ein bis drei Bytes übrig, passt die Folge nicht
            // auf, und ein anderer Entpacker liest sie womöglich anders.
            guard cursor == extraField.count else {
                throw ArchiveError("a ZIP entry has a malformed extra field")
            }
            return unicodeName
        }

        private static func crc32(of data: Data) -> UInt32 {
            data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress, !buffer.isEmpty else {
                    return UInt32(zlib.crc32(0, nil, 0))
                }
                return UInt32(zlib.crc32(0, baseAddress.assumingMemoryBound(to: Bytef.self),
                                         uInt(buffer.count)))
            }
        }

        /// CP437 ist die Standard-Kodierung für ZIP-Namen ohne Bit 11. Die
        /// untere Hälfte ist ASCII, die obere folgt dieser Tabelle.
        private static let cp437HighHalf: [Character] = [
            "Ç", "ü", "é", "â", "ä", "à", "å", "ç", "ê", "ë", "è", "ï", "î", "ì", "Ä", "Å",
            "É", "æ", "Æ", "ô", "ö", "ò", "û", "ù", "ÿ", "Ö", "Ü", "¢", "£", "¥", "₧", "ƒ",
            "á", "í", "ó", "ú", "ñ", "Ñ", "ª", "º", "¿", "⌐", "¬", "½", "¼", "¡", "«", "»",
            "░", "▒", "▓", "│", "┤", "╡", "╢", "╖", "╕", "╣", "║", "╗", "╝", "╜", "╛", "┐",
            "└", "┴", "┬", "├", "─", "┼", "╞", "╟", "╚", "╔", "╩", "╦", "╠", "═", "╬", "╧",
            "╨", "╤", "╥", "╙", "╘", "╒", "╓", "╫", "╪", "┘", "┌", "█", "▄", "▌", "▐", "▀",
            "α", "ß", "Γ", "π", "Σ", "σ", "µ", "τ", "Φ", "Θ", "Ω", "δ", "∞", "φ", "ε", "∩",
            "≡", "±", "≥", "≤", "⌠", "⌡", "÷", "≈", "°", "∙", "·", "√", "ⁿ", "²", "■", "\u{00A0}",
        ]

        private static func cp437Name(of rawName: Data) -> String {
            String(rawName.map { byte in
                byte < 0x80
                    ? Character(UnicodeScalar(byte))
                    : Self.cp437HighHalf[Int(byte) - 0x80]
            })
        }

        /// Der Name ohne abschließenden Slash: ZIP markiert Verzeichnisse so,
        /// gemeint ist aber derselbe Pfad wie bei einer gleichnamigen Datei.
        private static func logicalName(of name: String) -> String {
            name.hasSuffix("/") ? String(name.dropLast()) : name
        }

        private static func validateEntryName(_ name: String) throws {
            let logicalName = Self.logicalName(of: name)
            let components = logicalName.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            guard !logicalName.isEmpty,
                  !name.hasPrefix("/"),
                  !name.contains("\\"),
                  !name.contains("\0"),
                  !components.contains(where: {
                      $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(":")
                  }) else {
                throw ArchiveError("the ZIP package contains an unsafe entry path")
            }
        }
    }

    /// Die beiden Lesarten eines Eintragsnamens. Ohne Unicode-Path-Extrafeld
    /// sind sie gleich; mit Feld liest ein regelkonformer Entpacker `effective`
    /// und ein Verbraucher ohne Unterstützung dafür `rawDecoded`. Geprüft werden
    /// muss deshalb beides.
    private struct EntryNames {
        let effective: String
        let rawDecoded: String
    }

    fileprivate struct Entry {
        let name: String
        let rawName: Data
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let isDirectory: Bool
    }

    private enum Limits {
        static let maximumArchiveSize = 1_073_741_824
        static let maximumEntryCount = 10_000
        static let maximumUncompressedSize = 1_073_741_824
        static let maximumMetadataEntrySize = 16_777_216
    }

    fileprivate final class ArchiveBytes {
        let count: Int
        private let owned: VerifiedFile.Owned?
        private let mapped: Data?
        private var cache = Data()
        private var cacheOffset = 0
        var layoutValidated = false

        init(url: URL, mapsPrivateCopy: Bool) throws {
            let fileOwner = try VerifiedFile.openRetained(at: url, failure: packageFailure)
            let package = fileOwner.file
            guard package.isRegularFile else {
                throw ArchiveError("the package is not a regular file")
            }
            guard package.info.st_size >= 0,
                  package.info.st_size <= Int64(Limits.maximumArchiveSize) else {
                throw ArchiveError("the package exceeds the supported archive-size limit")
            }
            count = Int(package.info.st_size)
            if mapsPrivateCopy {
                if count > 0, isOnALocalVolume(package.descriptor),
                   let bytes = mappedContents(package.descriptor, length: count) {
                    mapped = bytes
                } else {
                    mapped = try readContents(package, length: count)
                }
                owned = nil
            } else {
                mapped = nil
                owned = fileOwner
            }
        }

        func bytes(in range: Range<Int>) throws -> Data {
            guard range.lowerBound >= 0, range.upperBound <= count else {
                throw ArchiveError("the ZIP byte range is invalid")
            }
            if let mapped { return mapped[range] }
            if range.isEmpty { return Data() }
            if range.lowerBound >= cacheOffset, range.upperBound <= cacheOffset + cache.count {
                return cache.subdata(in: (range.lowerBound - cacheOffset)..<(range.upperBound - cacheOffset))
            }
            let length = range.count <= 65_536 ? min(65_536, count - range.lowerBound) : range.count
            var bytes = Data(count: length)
            try bytes.withUnsafeMutableBytes { buffer in
                var consumed = 0
                while consumed < length {
                    try ConversionExecution.check()
                    let amount = pread(owned!.file.descriptor, buffer.baseAddress!.advanced(by: consumed),
                                       length - consumed, off_t(range.lowerBound + consumed))
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw ArchiveError("the package could not be read completely") }
                    consumed += amount
                }
            }
            if range.count <= 65_536 {
                cache = bytes
                cacheOffset = range.lowerBound
                return bytes.subdata(in: 0..<range.count)
            }
            return bytes
        }

        func subdata(in range: Range<Int>) throws -> Data {
            if let mapped { return mapped.subdata(in: range) }
            return try bytes(in: range)
        }
        func uint16(at offset: Int) throws -> UInt16 {
            guard offset >= 0, offset <= count - 2 else { return 0 }
            if let mapped { return mapped.uint16(at: offset) }
            if offset < cacheOffset || offset + 2 > cacheOffset + cache.count {
                _ = try bytes(in: offset..<(offset + 2))
            }
            return cache.uint16(at: offset - cacheOffset)
        }
        func uint32(at offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= count - 4 else { return 0 }
            if let mapped { return mapped.uint32(at: offset) }
            if offset < cacheOffset || offset + 4 > cacheOffset + cache.count {
                _ = try bytes(in: offset..<(offset + 4))
            }
            return cache.uint32(at: offset - cacheOffset)
        }
    }

    /// Die Fehlertexte dieses Lesers. `VerifiedFile` kennt nur den Anlass.
    private static func packageFailure(_ reason: VerifiedFile.Failure) -> Error {
        switch reason {
        case .couldNotOpen:
            ArchiveError("the package could not be opened")
        case .couldNotInspect:
            ArchiveError("the package could not be inspected")
        case .couldNotRead:
            ArchiveError("the package could not be read")
        }
    }

    /// Abgebildet wird nur von einem lokalen Datenträger. Kürzt jemand eine
    /// abgebildete Datei, endet jeder Zugriff hinter dem neuen Ende mit SIGBUS —
    /// auf einem Netzlaufwerk kann das jederzeit ein anderer Rechner tun. Genau
    /// diese Unterscheidung traf bisher das `ifSafe` in `.mappedIfSafe`.
    ///
    /// „Lokal" allein reicht allerdings nicht: `MAP_PRIVATE` schützt die
    /// Abbildung nur vor fremden SCHREIBVORGÄNGEN, nicht vor dem KÜRZEN
    /// desselben Inodes. Kürzt ein Programm auf demselben Rechner — etwa ein
    /// Cloud-Abgleich, der die Datei gerade ersetzt — das ausgewählte Dokument
    /// während der Erkennung, beendet SIGBUS den ganzen Prozess, und kein
    /// Swift-`catch` fängt das ab. Deshalb wird nur noch die eigene, gerade
    /// selbst geschriebene Arbeitskopie abgebildet; fremde Originale werden
    /// gelesen (Review-Fund 2026-08-20).
    private static func isOnALocalVolume(_ descriptor: Int32) -> Bool {
        var fileSystem = statfs()
        guard fstatfs(descriptor, &fileSystem) == 0 else {
            return false
        }
        return fileSystem.f_flags & UInt32(MNT_LOCAL) != 0
    }

    /// Ein zulässiges Archiv darf 1 GiB groß sein, und der Parser liest daraus nur
    /// wenige Bereiche. Eine Abbildung kostet deshalb deutlich weniger Speicher
    /// als eine Vollkopie.
    private static func mappedContents(_ descriptor: Int32, length: Int) -> Data? {
        guard let base = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0),
              base != MAP_FAILED else {
            return nil
        }
        return Data(
            bytesNoCopy: base,
            count: length,
            deallocator: .custom { pointer, size in munmap(pointer, size) }
        )
    }

    /// Rückfall ohne Abbildung: genau die bei `fstat` gesehenen Bytes lesen.
    /// Wächst die Datei dabei, bleibt der Rest ungelesen — das Budget kann sie so
    /// nicht überziehen.
    private static func readContents(_ package: VerifiedFile, length: Int) throws -> Data {
        var data = Data(count: length)
        let readBytes = try data.withUnsafeMutableBytes { raw in
            try package.readFully(into: raw)
        }
        // Kürzt jemand die Datei während des Lesens, bleibt der Rest aus. Ein
        // halb gelesenes Archiv wird nicht geparst.
        guard readBytes == length else {
            throw ArchiveError("the package could not be read completely")
        }
        return data
    }

    private static func inflate(
        _ compressed: Data,
        expectedSize: Int,
        entryName: String
    ) throws -> Data {
        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw ArchiveError("zlib could not initialize for \(entryName)")
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data(count: max(expectedSize + 1, 1))
        let status = try compressed.withUnsafeBytes { inputBuffer in
            try output.withUnsafeMutableBytes { outputBuffer -> Int32 in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inputBuffer.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(inputBuffer.count)
                var status = Z_OK
                while status == Z_OK {
                    try ConversionExecution.check()
                    let offset = Int(stream.total_out)
                    guard offset < outputBuffer.count else { return Z_BUF_ERROR }
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress?.advanced(by: offset)
                    stream.avail_out = uInt(min(65_536, outputBuffer.count - offset))
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                }
                return status
            }
        }
        guard status == Z_STREAM_END,
              Int(stream.total_out) == expectedSize, stream.avail_in == 0 else {
            throw ArchiveError("the compressed data for \(entryName) is invalid")
        }
        output.count = expectedSize
        return output
    }

    /// Entpackt einen Deflate-Eintrag blockweise, ohne das Ergebnis zu behalten,
    /// und vergleicht Größe und CRC-32 mit dem Verzeichniseintrag. Sobald mehr
    /// Bytes entstehen als deklariert, endet der Lauf sofort — genau das ist der
    /// Schutz gegen einen klein deklarierten, in Wahrheit riesigen Eintrag.
    private static func verifyDeflated(
        _ compressed: Data,
        expectedSize: Int,
        expectedChecksum: UInt32,
        entryName: String
    ) throws {
        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw ArchiveError("zlib could not initialize for \(entryName)")
        }
        defer {
            inflateEnd(&stream)
        }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        var produced = 0
        var checksum = zlib.crc32(0, nil, 0)
        var status = Z_OK

        compressed.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: input.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(input.count)

            while status == Z_OK {
                if ConversionExecution.isCancelled { return }
                status = buffer.withUnsafeMutableBufferPointer { output -> Int32 in
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    let step = zlib.inflate(&stream, Z_NO_FLUSH)
                    let chunk = output.count - Int(stream.avail_out)
                    if chunk > 0, let baseAddress = output.baseAddress {
                        checksum = zlib.crc32(checksum, baseAddress, uInt(chunk))
                        produced += chunk
                    }
                    return step
                }
                if produced > expectedSize {
                    return
                }
            }
        }

        try ConversionExecution.check()
        guard produced <= expectedSize else {
            throw ArchiveError("\(entryName) expands beyond the size declared in the ZIP directory")
        }
        guard status == Z_STREAM_END, produced == expectedSize, stream.avail_in == 0 else {
            throw ArchiveError("the compressed data for \(entryName) is invalid")
        }
        guard UInt32(truncatingIfNeeded: checksum) == expectedChecksum else {
            throw ArchiveError("the checksum of \(entryName) is invalid")
        }
    }

    private static func verifyChecksum(
        of content: Data,
        expected: UInt32,
        entryName: String
    ) throws {
        let checksum = try content.withUnsafeBytes { buffer -> UInt32 in
            var checksum = zlib.crc32(0, nil, 0)
            guard let base = buffer.bindMemory(to: Bytef.self).baseAddress else { return UInt32(checksum) }
            for offset in stride(from: 0, to: buffer.count, by: 65_536) {
                try ConversionExecution.check()
                checksum = zlib.crc32(checksum, base.advanced(by: offset), uInt(min(65_536, buffer.count - offset)))
            }
            return UInt32(checksum)
        }
        guard checksum == expected else {
            throw ArchiveError("the checksum of \(entryName) is invalid")
        }
    }

    private struct ArchiveError: LocalizedError {
        let reason: String

        init(_ reason: String) {
            self.reason = reason
        }

        var errorDescription: String? {
            reason
        }
    }
}


/// Gemeinsame Leseoberfläche; ein Inspektionssnapshot ist keine Berechtigung,
/// ihn an ein externes Konvertierungswerkzeug weiterzugeben.
protocol ZIPPackageReading {
    var entryNames: Set<String> { get }
    func data(named name: String) throws -> Data
}

extension ZIPPackageReading {
    func dataIfPresent(named name: String) throws -> Data? {
        try entryNames.contains(name) ? data(named: name) : nil
    }
    func string(named name: String) throws -> String {
        String(decoding: try data(named: name), as: UTF8.self)
    }
    func contents(entryNames names: [String]) throws -> ZIPPackageContents {
        var entries: [String: Data] = [:]
        for name in names where entryNames.contains(name) && entries[name] == nil {
            entries[name] = try data(named: name)
        }
        return ZIPPackageContents(entryNames: entryNames, entries: entries)
    }
}

/// Liest bedarfsgerecht aus einer vollständig geprüften Arbeitskopie. Entpackte
/// Einträge werden nicht gesammelt: Der Aufrufer bestimmt die XML-Lebensdauer.
final class ZIPPackageReader: ZIPPackageReading {
    let url: URL
    let entryNames: Set<String>
    private let archive: ZIPArchiveInspector.Archive

    fileprivate init(url: URL, archive: ZIPArchiveInspector.Archive) {
        self.url = url
        self.archive = archive
        entryNames = Set(archive.entries.map(\.name))
    }
    func data(named name: String) throws -> Data { try archive.data(named: name) }
}

private struct ZIPInspectionSnapshot: ZIPPackageReading {
    let entryNames: Set<String>
    private let archive: ZIPArchiveInspector.Archive
    init(archive: ZIPArchiveInspector.Archive) {
        self.archive = archive
        entryNames = Set(archive.entries.map(\.name))
    }
    func data(named name: String) throws -> Data { try archive.data(named: name) }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            return 0
        }
        return UInt16(self[offset])
            | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            return 0
        }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
