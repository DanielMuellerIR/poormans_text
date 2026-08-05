# Bauen, testen und installieren

## Lokaler Build

Vom Repo-Root:

```sh
./build.sh          # Release
./build.sh debug
swift test
```

`build.sh` ist ein dünner Wrapper für `scripts/build_app.sh`. Release-Builds sind
Universal Binaries für `arm64` und `x86_64`; Debug-Builds verwenden die lokale
Architektur. Ein erfolgreicher Lauf legt zwei gitignorierte Artefakte sichtbar
im Repo-Root ab:

- `Poor Man's Text.app`
- `poormans-text`

Das App-Bundle enthält die CLI unter `Contents/Resources/poormans-text`, die
Projektlizenz unter `Contents/Resources/LICENSE.txt` und das aus
`Assets/AppIcon.png` erzeugte App-Icon. `scripts/build_icon.sh` baut daraus das
vollständige ICNS-Größenset unter `.build/icon/`. Lokale Builds sind ad-hoc-signiert
und dürfen nicht nach `/Applications` kopiert werden.

Dazu kommt der Updater: `scripts/build_app.sh` kopiert das von SwiftPM
aufgelöste `Sparkle.framework` nach `Contents/Frameworks` und Sparkles Lizenz
nach `Contents/Resources/Sparkle-LICENSE.txt`. Ohne diesen Schritt startet die
App nicht, weil dyld Sparkle zur Laufzeit nur dort findet. Sparkles XPC-Dienste
werden entfernt: Poor Man's Text ist nicht sandboxed und braucht sie nicht.
Signiert wird über `scripts/sign_bundle.sh` — beim lokalen Build ad-hoc, beim
Release mit Developer ID, in beiden Fällen von innen nach außen (eingebettete
CLI, `Autoupdate`, `Updater.app`, Framework, zuletzt die App). Der
Veröffentlichungsweg des Update-Feeds steht in
[SPARKLE-RELEASE.md](SPARKLE-RELEASE.md).

## Schneller Developer-ID-Test

```sh
./install.sh --no-notarize
```

Dieser Modus baut Release, signiert App und eingebettete CLI mit Developer ID,
Hardened Runtime und Zeitstempel und prüft das Bundle. Er belässt alles im
Repo-Root und verändert weder `/Applications` noch einen globalen CLI-Pfad.

## Vollständige Installation

Voraussetzungen sind ein Developer-ID-Application-Zertifikat und ein lokales
`notarytool`-Keychain-Profil. Der Profilname kann nur für den aktuellen Clone
gespeichert oder pro Lauf übergeben werden:

```sh
git config --local poormansText.notaryProfile <profil>
./install.sh

NOTARY_PROFILE=<profil> ./install.sh
```

Credentials bleiben im Schlüsselbund. Fehlt das Profil, kann das Skript es in
einer interaktiven lokalen Terminalsitzung über `notarytool store-credentials`
einrichten; das App-Passwort wird nie als Argument oder Datei verarbeitet.

`./install.sh` führt in dieser Reihenfolge aus:

1. Release-Build mit eingebetteter CLI.
2. Developer-ID-Signatur von innen nach außen, Hardened Runtime und Zeitstempel.
3. ZIP-Einreichung bei Apple mit `notarytool --wait`.
4. Ticket stapeln; Codesign, Stapler und Gatekeeper prüfen.
5. Die App nach `/Applications/Poor Man's Text.app` kopieren und erneut prüfen.
6. `poormans-text` im Terminalpfad auf die exakt gleiche eingebettete CLI
   verlinken und die Versionsgleichheit prüfen.

Dieser Lauf erzeugt **kein** DMG. Der Root-Wrapper ruft `scripts/install.sh` mit
`--no-dmg` auf; das Distributionspaket baut `./release.sh` (siehe unten). Für ein
vollständiges Release gibt es `./install.sh --with-dmg` — ein Lauf, der beides
aus demselben signierten Bundle erzeugt.

Das CLI-Verzeichnis ermittelt der Installer selbst: Liegt bereits ein
`poormans-text` im `PATH`, gewinnt dessen Verzeichnis — sonst entstünde eine
zweite Kopie, die von der älteren verschattet würde. Sonst nimmt er das erste
Homebrew-`bin` im `PATH` (`/opt/homebrew/bin`, auf Intel `/usr/local/bin`) und
andernfalls `/usr/local/bin`.

Ein fremdes vorhandenes App- oder CLI-Ziel wird nicht überschrieben. Ist das
Zielverzeichnis nicht beschreibbar, fordert der Installer im Terminal
Administratorrechte an. Ein anderes absolutes Ziel kann für kontrollierte Tests
über `CLI_INSTALL_DIR` gesetzt werden; es muss im aktuellen `PATH` liegen.

Beim atomaren Austausch bleibt die bisherige App bis zur erfolgreichen
Endprüfung an einem eindeutigen Stage-Pfad erhalten. Schlägt auch der Rücktausch
fehl, löscht der Cleanup diesen Rettungspfad nicht, meldet ihn ausdrücklich und
beendet den Lauf mit einem Fehlerstatus.

## Distributionspaket

```sh
./release.sh
```

`./release.sh` teilt sich mit `./install.sh` Build, Signatur, App-Notarisierung
und Zielprüfung (Schritte 1 bis 4) und schließt statt der Installation so ab:

5. Signiertes DMG mit der gestapelten App und einem `/Applications`-Link bauen.
6. DMG separat notarisieren, stapeln, per Gatekeeper prüfen, headless mounten und
   eine SHA-256-Datei erzeugen.

Ergebnis sind `Poor-Mans-Text-<Version>.dmg` und
`Poor-Mans-Text-<Version>.dmg.sha256` im Repo-Root; `/Applications` bleibt
unberührt. Existiert das Paar dieser Version schon, bricht der Lauf mit Exit 73
ab. Nach manueller Installation aus dem DMG bietet die App die CLI-Einrichtung
beim ersten Start optional an.

## Vollständiges Release in einem Lauf

```sh
./install.sh --with-dmg
```

Beide Wege gehen über dasselbe `scripts/install.sh`, das die Root-Wrapper mit
`--no-dmg` beziehungsweise `--no-install` ansteuern. `--with-dmg` hebt die
Vorgabe des Installations-Wrappers wieder auf, sodass ein einziger Lauf baut,
signiert, notarisiert, das DMG samt Checksumme erzeugt **und** installiert.

Das ist bewusst der einzige Weg zu einem vollständigen Release, denn
`scripts/verify_release.sh` verlangt alle Artefakte auf einmal und vergleicht die
CodeDirectory-Hashes von Repo-App, installierter App und der App im DMG. Zwei
getrennte Läufe (`./release.sh`, danach `./install.sh`) bauen, signieren und
notarisieren zweimal und überschreiben dabei jeweils die App im Repo-Root; die
drei Kopien stammen dann nicht aus demselben signierten Bundle und der Vergleich
scheitert zu Recht. `./release.sh` allein bleibt richtig, wenn nur ein DMG
gebraucht wird, `./install.sh` allein, wenn nur installiert werden soll.

Die Auswertung der Betriebsarten steht in `scripts/install_modes.sh`, damit sie
ohne Build, Signatur und Notarisierung testbar ist
(`Tests/PoorMansTextCoreTests/InstallModeTests.swift`). Mit `--no-notarize` endet
jeder Lauf weiterhin nach Build und Signatur: ohne Ticket entsteht kein DMG, und
`/Applications` bleibt unberührt.

## Verifikation

Vor einem Release mindestens:

```sh
swift test
./build.sh
scripts/verify_bundle.sh "Poor Man's Text.app"
```

Zusätzlich je ein echtes RTF, RTFD, DOCX, ODT und DOC über die gebaute Root-CLI
konvertieren, vorhandene Bilder per Hash vergleichen und die App als Bundle ohne
Fokuswechsel starten. DOCX und ODT müssen aus einem anderen Erzeuger als die
Unit-Testdatei stammen; DOC wird wegen möglicher Systemimportverluste zusätzlich
inhaltlich gegen `textutil -convert txt` geprüft.
Für einen installierten Build und das DMG müssen `stapler`, `spctl`, `codesign`
und `hdiutil verify` am tatsächlichen Ziel erfolgreich sein; ein grüner
SwiftPM-Build allein genügt nicht.

Nach Commit, annotiertem Release-Tag und vollständiger Notarisierung prüft
`scripts/verify_release.sh <Version>` zusätzlich einen sauberen Git-Stand, die
Tag- und Versionsgleichheit, Universal Binaries, beide App-Kopien, DMG und
SHA-256-Datei. Der öffentliche Ablauf steht in
[GITHUB-RELEASE.md](GITHUB-RELEASE.md).
