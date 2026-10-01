import Foundation
import PoorMansTextCore

/// Führt ein Hilfsprogramm der App aus, verwirft dessen Standardausgabe und
/// liefert Exit-Status und bereinigte Fehlerausgabe zurück.
///
/// Der eigentliche Prozessstart läuft über `ProcessRunner` aus dem Kern: Der
/// prüft Zeitlimit und Abbruch alle 10 ms, beendet die eigene Prozessgruppe
/// erst mit TERM und dann mit KILL, schreibt die Ausgaben in Dateien statt in
/// Pipes (kein Deadlock bei gesprächigen Kindern) und gibt dem Kind
/// `/dev/null` als Standardeingabe. Letzteres ist wichtig: Ein Homebrew, das
/// auf eine Passwort- oder Bestätigungsabfrage wartet, hängt so nicht ewig,
/// sondern läuft sofort auf EOF.
enum CapturedProcess {
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval? = nil,
        cancellation: ConversionCancellationToken? = nil
    ) throws -> (status: Int32, standardError: String) {
        // Die Ausgabedateien des Runners landen im temporären Verzeichnis
        // des Nutzers; das ist zugleich das Arbeitsverzeichnis des Kindes.
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            currentDirectory: FileManager.default.temporaryDirectory,
            timeout: timeout,
            cancellation: cancellation
        )
        let message = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.status, message)
    }
}
