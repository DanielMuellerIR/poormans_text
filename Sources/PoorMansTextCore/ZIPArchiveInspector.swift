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

    /// Die Erkennung bleibt beim nichtgemappten Deskriptorsnapshot. Namen,
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
        let data: Data
        let entries: [Entry]
        private let entriesByName: [String: Entry]

        /// - Parameter mapsPrivateCopy: nur `true` für eine Datei, die dieser
        ///   Prozess gerade selbst in seinen Arbeitsordner geschrieben hat.
        ///   Fremde Originale werden gelesen statt abgebildet.
        init(url: URL, mapsPrivateCopy: Bool = false) throws {
            // Prüfung und Bytes gehören zu EINEM Deskriptor — siehe
            // `ZIPArchiveInspector.verifiedContents(of:mapsPrivateCopy:)`. Ein
            // Verweis auf ein gültiges Paket bleibt dabei erlaubt: `open` folgt
            // ihm, und `fstat` beschreibt danach die Datei dahinter statt den
            // Verweis selbst.
            data = try ZIPArchiveInspector.verifiedContents(
                of: url,
                mapsPrivateCopy: mapsPrivateCopy
            )
            guard let endOffset = Self.endOfCentralDirectory(in: data) else {
                throw ArchiveError("the ZIP central directory is missing")
            }
            guard data.uint16(at: endOffset + 4) == 0,
                  data.uint16(at: endOffset + 6) == 0 else {
                throw ArchiveError("multi-disk ZIP packages are not supported")
            }

            let entryCount = Int(data.uint16(at: endOffset + 10))
            let centralSize = Int(data.uint32(at: endOffset + 12))
            let centralOffset = Int(data.uint32(at: endOffset + 16))
            guard entryCount != Int(UInt16.max),
                  centralSize != Int(UInt32.max),
                  centralOffset != Int(UInt32.max) else {
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
            var offset = centralOffset

            for _ in 0..<entryCount {
                try ConversionExecution.check()
                guard data.uint32(at: offset) == 0x02014B50 else {
                    throw ArchiveError("the ZIP central directory contains an invalid entry")
                }
                let flags = data.uint16(at: offset + 8)
                let method = data.uint16(at: offset + 10)
                let crc = data.uint32(at: offset + 16)
                let compressedSize = Int(data.uint32(at: offset + 20))
                let uncompressedSize = Int(data.uint32(at: offset + 24))
                let nameLength = Int(data.uint16(at: offset + 28))
                let extraLength = Int(data.uint16(at: offset + 30))
                let commentLength = Int(data.uint16(at: offset + 32))
                let externalAttributes = data.uint32(at: offset + 38)
                let localHeaderOffset = Int(data.uint32(at: offset + 42))
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

                let rawName = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
                let extraField = data.subdata(
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

            guard offset == centralOffset + centralSize else {
                throw ArchiveError("the ZIP central directory size is inconsistent")
            }
            entries = parsedEntries
            entriesByName = Dictionary(uniqueKeysWithValues: parsedEntries.map { ($0.name, $0) })
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
            let contentRange = try contentRange(for: entry)

            let result: Data
            switch entry.method {
            case 0:
                result = Data(data[contentRange])
            case 8:
                result = try inflate(
                    data[contentRange],
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
        /// `data[contentRange]` liefert einen Ausschnitt auf denselben Speicher.
        /// `subdata(in:)` würde stattdessen jeden Eintrag zusätzlich kopieren —
        /// bei einem zulässigen Archiv von bis zu 1 GiB wäre die angeblich
        /// streamende Prüfung dann der größte Speicherverbraucher überhaupt.
        func verifyEntryContents() throws {
            for entry in entries where !entry.isDirectory {
                try ConversionExecution.check()
                let contentRange = try contentRange(for: entry)
                switch entry.method {
                case 0:
                    guard entry.compressedSize == entry.uncompressedSize else {
                        throw ArchiveError(
                            "the stored size of \(entry.name) does not match its declared size"
                        )
                    }
                    try ZIPArchiveInspector.verifyChecksum(
                        of: data[contentRange],
                        expected: entry.crc,
                        entryName: entry.name
                    )
                case 8:
                    try ZIPArchiveInspector.verifyDeflated(
                        data[contentRange],
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
            guard data.uint32(at: offset) == 0x04034B50 else {
                throw ArchiveError("the local ZIP header for \(entry.name) is invalid")
            }
            let localFlags = data.uint16(at: offset + 6)
            let localMethod = data.uint16(at: offset + 8)
            let nameLength = Int(data.uint16(at: offset + 26))
            let extraLength = Int(data.uint16(at: offset + 28))
            let contentStart = offset + 30 + nameLength + extraLength
            let contentEnd = contentStart + entry.compressedSize
            guard localFlags == entry.flags,
                  localMethod == entry.method,
                  entry.compressedSize >= 0,
                  contentEnd <= data.count,
                  data.subdata(in: (offset + 30)..<(offset + 30 + nameLength))
                    == entry.rawName else {
                throw ArchiveError("the local ZIP entry for \(entry.name) is inconsistent")
            }
            // Das Extrafeld steht zweimal im Archiv, und manche Verbraucher lesen
            // den Namen aus dem lokalen Header. Ein eigenes Unicode-Path-Feld dort
            // ergäbe für sie einen anderen Pfad als den hier geprüften, deshalb
            // muss der wirksame Name beider Kopien übereinstimmen. Verglichen wird
            // nur dieses eine Feld: Die übrigen Extrafelder dürfen sich regulär
            // unterscheiden — Info-ZIP schreibt lokal etwa mehr Zeitstempel als
            // zentral.
            let localExtraField = data.subdata(
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

        private static func endOfCentralDirectory(in data: Data) -> Int? {
            guard data.count >= 22 else {
                return nil
            }
            let lowerBound = max(0, data.count - 65_557)
            for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
                if data.uint32(at: offset) == 0x06054B50 {
                    let commentLength = Int(data.uint16(at: offset + 20))
                    if offset + 22 + commentLength == data.count {
                        return offset
                    }
                }
            }
            return nil
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

    /// Der Archivinhalt, geprüft und gelesen über GENAU EINEN Deskriptor.
    ///
    /// Vorher prüfte `resourceValues` den aufgelösten PFAD auf reguläre Datei und
    /// Größe, und `Data(contentsOf:)` öffnete den Pfad danach ein zweites Mal.
    /// Zeigte ein Eingabe-Symlink dazwischen auf etwas anderes, gehörten Prüfung
    /// und gelesene Bytes zu verschiedenen Objekten: Die 1-GiB-Grenze und die
    /// Regularitätsprüfung galten dann für eine Datei, die nie jemand gelesen hat.
    /// Die Erkennung öffnet Archive vor dem sicheren Staging, dort war das also
    /// erreichbar (Review-Fund 2026-08-19).
    private static func verifiedContents(of url: URL, mapsPrivateCopy: Bool) throws -> Data {
        try VerifiedFile.open(at: url, failure: packageFailure) { package in
            guard package.isRegularFile else {
                throw ArchiveError("the package is not a regular file")
            }
            guard package.info.st_size <= Int64(Limits.maximumArchiveSize) else {
                throw ArchiveError("the package exceeds the supported archive-size limit")
            }
            let length = Int(package.info.st_size)
            guard length > 0 else {
                return Data()
            }

            if mapsPrivateCopy,
               isOnALocalVolume(package.descriptor),
               let mapped = mappedContents(package.descriptor, length: length) {
                return mapped
            }
            return try readContents(package, length: length)
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
              Int(stream.total_out) == expectedSize else {
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
        guard status == Z_STREAM_END, produced == expectedSize else {
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
