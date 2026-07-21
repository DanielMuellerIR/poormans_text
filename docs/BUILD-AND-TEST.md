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

Das App-Bundle enthält die CLI unter `Contents/Resources/poormans-text` und die
Projektlizenz unter `Contents/Resources/LICENSE.txt`. Lokale Builds sind
ad-hoc-signiert und dürfen nicht nach `/Applications` kopiert werden.

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

Der Vollpfad führt in dieser Reihenfolge aus:

1. Release-Build mit eingebetteter CLI.
2. Developer-ID-Signatur von innen nach außen, Hardened Runtime und Zeitstempel.
3. ZIP-Einreichung bei Apple mit `notarytool --wait`.
4. Ticket stapeln; Codesign, Stapler und Gatekeeper prüfen.
5. Signiertes DMG mit der gestapelten App und einem `/Applications`-Link bauen.
6. DMG separat notarisieren, stapeln, per Gatekeeper prüfen, headless mounten und
   eine SHA-256-Datei erzeugen.
7. Erst danach die App nach `/Applications/Poor Man's Text.app` kopieren und
   erneut prüfen.
8. `/usr/local/bin/poormans-text` auf die exakt gleiche eingebettete CLI
   verlinken und die Versionsgleichheit prüfen.

Der Lauf erzeugt zusätzlich `Poor-Mans-Text-<Version>.dmg` und
`Poor-Mans-Text-<Version>.dmg.sha256` im Repo-Root. Nach manueller Installation
aus dem DMG bietet die App die CLI-Einrichtung beim ersten Start optional an.

Ein fremdes vorhandenes App- oder CLI-Ziel wird nicht überschrieben. Falls
`/usr/local/bin` nicht beschreibbar ist, fordert der Installer im Terminal
Administratorrechte an. Ein anderes absolutes Ziel kann für kontrollierte Tests
über `CLI_INSTALL_DIR` gesetzt werden; es muss im aktuellen `PATH` liegen.

## Verifikation

Vor einem Release mindestens:

```sh
swift test
./build.sh
scripts/verify_bundle.sh "Poor Man's Text.app"
```

Zusätzlich je ein echtes RTF und RTFD über die gebaute Root-CLI konvertieren,
Bilder per Hash vergleichen und die App als Bundle ohne Fokuswechsel starten.
Für einen installierten Build und das DMG müssen `stapler`, `spctl`, `codesign`
und `hdiutil verify` am tatsächlichen Ziel erfolgreich sein; ein grüner
SwiftPM-Build allein genügt nicht.
