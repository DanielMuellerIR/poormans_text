# Sparkle-Updates veröffentlichen

Poor Man's Text bindet Sparkle 2.9.4 exakt gepinnt per SwiftPM ein. Die App
prüft den Feed unter `https://danielmuellerir.github.io/poormans_text/appcast.xml`,
lädt das DMG aus dem zugehörigen GitHub Release und installiert ausschließlich
nach Zustimmung. Anonyme Hardware- und Systemprofildaten sind abgeschaltet.

Version 0.7.0 ist der einmalige Einstieg: 0.6.0 und älter enthalten noch keinen
Updater. Bestehende Installationen müssen 0.7.0 einmal von Hand per DMG
installieren; erst danach funktionieren Updates aus der App heraus.

Zwei unabhängige Prüfungen bleiben Pflicht:

- Developer-ID-Signatur und Apple-Notarisierung für App und DMG.
- Sparkle-Ed25519-Signatur für Update-Archiv und Feed.

Der private Sparkle-Schlüssel gehört weder in Git noch in Logs oder Argumente.
Nur sein öffentlicher Gegenpart steht als `SUPublicEDKey` in `App/Info.plist`.
Poor Man's Text benutzt bewusst dasselbe Schlüsselpaar wie Fastra und (seit
2026-08-06) MD Clip; es liegt im lokalen Schlüsselbund unter dem Dienst
`https://sparkle-project.org`. Eine Rotation beträfe damit alle drei Apps.

## Was im Projekt dazugehört

- `Package.swift` pinnt Sparkle exakt und gibt der App den zusätzlichen
  Suchpfad `@loader_path/../Frameworks`.
- `scripts/build_app.sh` kopiert `Sparkle.framework` ins Bundle, entfernt
  Sparkles XPC-Dienste (die App ist nicht sandboxed) und legt Sparkles Lizenz
  unter `Contents/Resources/Sparkle-LICENSE.txt` ab.
- `scripts/sign_bundle.sh` signiert von innen nach außen: eingebettete CLI,
  `Autoupdate`, `Updater.app`, Framework, zuletzt die App.
- `scripts/verify_bundle.sh` prüft Framework, Updater-Programme, die entfernten
  XPC-Dienste und die Update-Schlüssel der Info.plist.
- `Sources/PoorMansTextAppSupport/UpdateController.swift` hält den einen
  Updater der App-Laufzeit; der Menüpunkt „Check for Updates …" hängt daran.

## Einmalige GitHub-Einrichtung

1. In den Repository-Einstellungen unter **Pages** als Quelle **GitHub Actions**
   wählen. Das Environment `github-pages` muss neben dem Branch `main` auch
   Tags vom Typ `v*` zulassen, weil der automatische Lauf auf dem
   veröffentlichten Release-Tag startet.
2. Den privaten Schlüssel als Actions-Secret `SPARKLE_PRIVATE_KEY` hinterlegen.
   Sparkles `generate_keys -x` exportiert ihn vorübergehend in eine lokale
   Datei; `gh secret set SPARKLE_PRIVATE_KEY < datei` liest sie über stdin. Die
   Datei danach sicher entfernen. Den Schlüssel nie auf stdout ausgeben.
3. Den Schlüssel zusätzlich verschlüsselt sichern. Geht er verloren, ist eine
   kontrollierte Rotation über ein Developer-ID-signiertes DMG nötig — und zwar
   für Poor Man's Text, Fastra und MD Clip gemeinsam.

## Ablauf pro Release

1. Version in `Sources/PoorMansTextCore/ProductInfo.swift`, `App/Info.plist`,
   README und Changelog pflegen. `CFBundleVersion` muss monoton steigen; Sparkle
   vergleicht Versionen darüber.
2. Den Release in einem Lauf bauen: `./install.sh --with-dmg`. Danach
   `scripts/verify_release.sh <version>`. Beides ist in
   [GITHUB-RELEASE.md](GITHUB-RELEASE.md) beschrieben.
3. Tag und GitHub Release mit genau einem DMG anlegen. Die Release Notes sind
   der Text, den Sparkle später im Update-Dialog anzeigt; erst danach
   veröffentlichen.
4. `.github/workflows/publish-appcast.yml` erzeugt mit Sparkles
   `generate_appcast` den signierten Feed und veröffentlicht ihn über GitHub
   Pages.
5. Workflow und Feed prüfen. Eine ältere, bereits Sparkle-fähige und
   notarisiert installierte Version muss das Release finden, installieren und
   neu starten.

Der Workflow kann für ein bestehendes Tag manuell gestartet werden. Er erwartet
genau ein `*.dmg`; der Feed enthält nur das aktuelle Vollupdate und keine Deltas.
Die Prüfsummendatei des Releases stört dabei nicht — sie endet nicht auf `.dmg`.
Quellstand und Sparkle-Werkzeug stammen dabei exakt aus diesem Release-Tag, nicht
aus dem Branch, von dem der manuelle Lauf gestartet wurde.

## Absicherung des Workflows

- `swift package resolve` läuft vor dem Signierschritt ohne Secret. Erst der
  Signierschritt erhält `SPARKLE_PRIVATE_KEY`, übernimmt ihn in eine nicht
  exportierte Shell-Variable und entfernt ihn sofort aus der Umgebung. Im `env`
  des ganzen Jobs wäre der Schlüssel auch für Checkout, Paketmanifeste, Pages-
  und Deployment-Actions lesbar.
- Alle fremden Actions hängen an einem geprüften Commit-SHA mit der
  Versionsnummer als Kommentar. Ein beweglicher Major-Tag kann jederzeit auf
  anderen Code zeigen, der dann neben dem Schlüssel liefe. Beim Aktualisieren
  einer Action den neuen SHA aus dem Tag der Action auflösen und den Kommentar
  mitziehen.
- Ein Prerelease startet den Job nicht, und vor dem Download prüft ein eigener
  Schritt, dass das Tag das neueste stabile Release ist. Sonst könnte ein Lauf
  von Hand den Feed auf einen alten Stand zurücksetzen — allen Installationen
  wird immer genau dieser eine Appcast angeboten.
