import Combine
import Foundation
import Sparkle

/// Verbindet die App mit Sparkle. Sparkle selbst erledigt Suche, Download,
/// Prüfung der Ed25519-Signatur, Austausch der App und Neustart; hier steht nur
/// die Verdrahtung mit Menü und Oberfläche.
///
/// Der Controller lebt genau einmal für die App-Laufzeit. Eine zweite Instanz
/// würde einen zweiten Updater starten, der parallel denselben Feed abfragt.
@MainActor
public final class UpdateController: ObservableObject {
    /// Menütitel an einer Stelle, damit App und Test dieselbe Zeichenkette
    /// benutzen. Die Auslassungspunkte sind das typografische Zeichen „…",
    /// wie in den übrigen Menüpunkten der App.
    public static let menuTitle = "Check for Updates…"

    private let updaterController: SPUStandardUpdaterController

    /// Falsch, solange Sparkle gerade selbst sucht oder ein Update installiert.
    /// Der Menüpunkt folgt diesem Wert und ist dann ausgegraut.
    @Published public private(set) var canCheckForUpdates = false

    /// - Parameter startsUpdater: Startet den Updater sofort und lässt ihn im
    ///   eingestellten Intervall selbsttätig suchen. Tests setzen `false`: ohne
    ///   laufenden Updater fragt niemand den Feed ab.
    public init(startsUpdater: Bool = true) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startsUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // `canCheckForUpdates` ist KVO-fähig. Über den Publisher bleibt der
        // Menüpunkt auch dann richtig, wenn Sparkle den Zustand selbst ändert.
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Sucht sichtbar nach Updates. Sparkle zeigt dabei auch „Sie sind aktuell",
    /// anders als bei der stillen Hintergrundsuche.
    public func checkForUpdates() {
        guard canCheckForUpdates else {
            return
        }
        updaterController.updater.checkForUpdates()
    }

    /// Der Feed, den dieser Updater tatsächlich abfragt — aus der Info.plist des
    /// laufenden Bundles, nicht aus einer zweiten Konstante im Quelltext.
    public var feedURL: URL? {
        updaterController.updater.feedURL
    }
}
