import Foundation

/// Eine Quelldatei, die GENAU EINMAL geöffnet wurde und über denselben
/// Deskriptor beschrieben ist.
///
/// Der Kern öffnet fremde Dateien an mehreren Stellen: beim Staging, beim Lesen
/// eines ZIP-Pakets, bei der RTF-Kopfprüfung und bei der PDF-Signatur. Jede
/// dieser Stellen braucht dieselben zwei Dinge, und sie hatten sie zuletzt
/// jeweils eigenhändig:
///
/// - `O_NONBLOCK` beim Öffnen. Ohne das Flag kehrt ein `open` auf eine FIFO
///   ohne Schreiber NIE zurück, und die Umwandlung steht ohne Zeitgrenze. Über
///   ein Masterdokument, ein RTFD-Paket oder eine untergeschobene Eingabe war
///   das erreichbar (Review-Funde 2026-08-19 und 2026-08-20).
/// - `fstat` auf DEMSELBEN Deskriptor. Diese Auskunft gehört garantiert zu den
///   Bytes, die gleich gelesen werden — anders als eine Abfrage über den Pfad,
///   der inzwischen auf etwas anderes zeigen kann.
///
/// Was ein unerwarteter Objekttyp oder eine zu große Datei bedeutet,
/// entscheidet weiterhin der Aufrufer: Die ZIP-Signaturprüfung meldet dann
/// „kein Paket", das Staging einen ungültigen Eingabefehler. Auch die
/// Fehlertexte bleiben beim Aufrufer — er übergibt sie als `failure`.
struct VerifiedFile {
    /// Was beim Öffnen oder Lesen schiefgehen kann. Der Aufrufer macht daraus
    /// seinen eigenen Fehlertyp mit seinem eigenen Betreff („the package", „the
    /// PDF source").
    enum Failure {
        /// Das Öffnen scheiterte; der Text ist die `strerror`-Auskunft.
        case couldNotOpen(String)
        case couldNotInspect
        case couldNotRead
    }

    let descriptor: Int32
    /// Die Auskunft von `fstat` — Objekttyp und Größe des geöffneten Objekts.
    let info: stat
    private let failure: (Failure) -> Error

    /// Öffnet `url`, prüft sie mit `fstat` und übergibt beides an `body`. Der
    /// Deskriptor gilt nur innerhalb von `body`; danach ist er geschlossen.
    static func open<T>(
        at url: URL,
        failure: @escaping (Failure) -> Error,
        body: (VerifiedFile) throws -> T
    ) throws -> T {
        try open(at: url, flags: O_RDONLY | O_NONBLOCK, failure: failure, body: body)
    }

    /// Öffnet ein Paketmitglied, ohne einen symbolischen Verweis am letzten
    /// Pfadbestandteil zu verfolgen. Der äußere, vom Nutzer gewählte Verweis
    /// wird vorher bewusst einmal aufgelöst; innerhalb eines Dokumentpakets
    /// darf ein Verweis dagegen niemals aus dessen Baum herausführen.
    static func openWithoutFollowing<T>(
        at url: URL,
        failure: @escaping (Failure) -> Error,
        body: (VerifiedFile) throws -> T
    ) throws -> T {
        try open(
            at: url,
            flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW,
            failure: failure,
            body: body
        )
    }

    private static func open<T>(
        at url: URL,
        flags: Int32,
        failure: @escaping (Failure) -> Error,
        body: (VerifiedFile) throws -> T
    ) throws -> T {
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else {
            throw failure(.couldNotOpen(String(cString: strerror(errno))))
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw failure(.couldNotInspect)
        }
        return try body(VerifiedFile(descriptor: descriptor, info: info, failure: failure))
    }

    var isRegularFile: Bool {
        info.st_mode & S_IFMT == S_IFREG
    }

    /// Füllt `buffer` und gibt zurück, wie viele Bytes wirklich kamen. Weniger
    /// heißt: Die Datei war kürzer oder wurde inzwischen gekürzt — was das
    /// bedeutet, entscheidet der Aufrufer.
    ///
    /// Ein durch ein Signal unterbrochener Lesevorgang wird wiederholt; für die
    /// reguläre Datei, die nach `isRegularFile` als Einzige übrig bleibt, hat
    /// `O_NONBLOCK` keine Wirkung.
    func readFully(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        var offset = 0
        while offset < buffer.count {
            try ConversionExecution.check()
            let readBytes = read(descriptor, base + offset, buffer.count - offset)
            if readBytes == 0 {
                break
            }
            guard readBytes > 0 else {
                if errno == EINTR { continue }
                throw failure(.couldNotRead)
            }
            offset += readBytes
        }
        return offset
    }

    /// Liest blockweise weiter und reicht jeden gelesenen Block an `consume`.
    /// Rückgabe ist die Gesamtzahl gelesener Bytes; gibt `consume` `false`
    /// zurück, bleibt der Rest der Datei ungelesen.
    ///
    /// `maximumBytes` wird VOR dem Übernehmen geprüft: Eine Quelle, die während
    /// des Lesens wächst, darf das Budget weder auf der Platte noch im Speicher
    /// überziehen — deshalb entscheidet nicht die anfangs gemeldete Größe,
    /// sondern die tatsächlich gelesene Menge.
    func readChunks(
        maximumBytes: Int,
        chunkSize: Int,
        budgetExceeded: () -> Error,
        consume: (UnsafeRawBufferPointer) throws -> Bool
    ) throws -> Int {
        var readTotal = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try ConversionExecution.check()
            let readBytes = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(descriptor, base, chunkSize)
            }
            if readBytes == 0 { break }
            guard readBytes > 0 else {
                if errno == EINTR { continue }
                throw failure(.couldNotRead)
            }
            readTotal += readBytes
            guard readTotal <= maximumBytes else {
                throw budgetExceeded()
            }
            let wantsMore = try buffer.withUnsafeBytes { raw in
                try consume(UnsafeRawBufferPointer(rebasing: raw[0..<readBytes]))
            }
            guard wantsMore else { break }
        }
        return readTotal
    }
}
