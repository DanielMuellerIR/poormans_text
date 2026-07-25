<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="App-Icon von Poor Man's Text">
</p>

<h1 align="center">Poor Man's Text</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>RTF, RTFD, DOCX, ODT und DOC in Markdown mit extrahierten Bildern umwandeln.</strong>
</p>

Poor Man's Text wandelt Rich-Text-Dokumente (`.rtf`) und macOS-Dokumentpakete im
Format „Rich Text with Attachments“ (`.rtfd`) sowie DOCX, OpenDocument Text
(`.odt`) und alte Word-Dateien (`.doc`) in Ordner mit Markdown und separat
gespeicherten Bildern um.

Das Projekt stellt zwei Oberflächen für denselben Konvertierungskern bereit:

- `poormans-text`, ein automatisierbares Kommandozeilenwerkzeug
- eine native macOS-App zum Öffnen oder Ablegen unterstützter Textdokumente

Die Konvertierung ist bewusst verlustbehaftet. Markdown kann Dokumentstruktur,
Links, einfache Hervorhebungen, Listen und Bilder bewahren, aber nicht jede
Schrift, Anordnung oder TextKit-spezifische Eigenschaft.

## Ausgabe

Die Konvertierung eines unterstützten Dokuments erzeugt einen neuen Nachbarordner,
ohne die Quelle zu verändern:

```text
Dokument-markdown/
├── Dokument.md
└── images/
    ├── erstes-bild.png
    └── zweites-bild.jpg
```

Die Bildverweise in `Dokument.md` sind relativ und stehen an derselben
Textposition wie im Ausgangsdokument. Vorhandene Ausgabeordner werden nie
überschrieben.

Manuelle Zeilenumbrüche enden im Markdown mit zwei Leerzeichen. Chromatischer
Text aus RTFD wird als `==Text==` markiert. Diese von Fastra unterstützte
Schreibweise ist eine verbreitete Markdown-Erweiterung, gehört aber nicht zum
GFM-Standard; der konkrete Farbwert bleibt dabei nicht erhalten. Im bildsicheren
RTF-Import lassen sich Farbinformationen nicht erhalten; der Text bleibt erhalten
und der Konverter meldet den Verlust als Warnung.

## Voraussetzungen

- macOS 13 oder neuer
- [Pandoc](https://pandoc.org/installing.html)
- Swift 6.2 oder neuer für den Bau aus dem Quellcode

Der Konverter sucht Pandoc in den üblichen Homebrew-Verzeichnissen und danach
über `PATH`. Dem CLI kann mit `--pandoc PFAD` auch ein bestimmtes Programm
übergeben werden.

## Download

DMG und zugehörige `.sha256`-Datei stehen im
[neuesten GitHub-Release](../../releases/latest). Liegen beide Dateien im selben
Ordner, lässt sich der Download vor dem Öffnen prüfen:

```sh
shasum -a 256 -c Poor-Mans-Text-0.5.0.dmg.sha256
```

Danach das DMG öffnen und Poor Man's Text in den Programme-Ordner ziehen. Die
App ist mit Developer ID signiert, von Apple notarisiert und enthält die passende
universelle CLI. Pandoc bleibt eine getrennte Voraussetzung und lässt sich
beispielsweise mit `brew install pandoc` installieren.

## Kommandozeile

```sh
swift run poormans-text Dokument.rtfd
swift run poormans-text Dokument.rtf
swift run poormans-text Dokument.docx
swift run poormans-text Dokument.odt
swift run poormans-text Dokument.doc
swift run poormans-text --output Konvertiert Dokument.rtfd
swift run poormans-text --json Dokument.rtfd
```

Standardmäßig entsteht `Dokument-markdown` neben der Quelle. Alle Optionen zeigt
`swift run poormans-text --help`.

Die Exit-Codes folgen den üblichen `sysexits`-Werten: `64` für Aufruffehler,
`65` für ungültige Eingabedaten, `66` für eine fehlende Eingabe, `69` für ein
fehlendes Pandoc, `70` für einen fehlgeschlagenen Konvertierungsprozess, `73`
für eine Kollision am Ausgabeziel und `74` für einen Dateisystemfehler. Mit
`--json` werden Erfolge und Fehler als JSON auf der Standardausgabe gemeldet;
andernfalls gehen Diagnosen an die Standardfehlerausgabe. Eingaben werden als
Dateisystempfade und nicht über die Standardeingabe entgegengenommen.

## macOS-App

App und CLI lassen sich vom Repo-Root bauen:

```sh
./build.sh
open "Poor Man's Text.app"
```

Der Build legt `Poor Man's Text.app` und `poormans-text` zusätzlich direkt im
Repo-Root ab. Diese lokalen Artefakte sind ad-hoc-signiert und nicht für
`/Applications` bestimmt.

Ein RTF-, RTFD-, DOCX-, ODT- oder DOC-Dokument kann in das Fenster oder auf die
App gezogen oder über den Dateidialog ausgewählt werden. Die App zeigt das
Ergebnis und kann die erzeugte Markdown-Datei im Finder anzeigen.

Das erzeugte Bundle wird für lokale Tests ad-hoc signiert und bleibt unter
`.build/app/`. Es ist kein notarisierter Distributions-Build.

## Signierte Installation

Der vollständige Installer baut App und CLI als Universal Binaries, signiert
beide mit Developer ID und Hardened Runtime, notarisiert und stapelt die App,
erzeugt ein signiertes DMG, notarisiert und stapelt auch dieses und installiert
erst danach die geprüfte App:

```sh
NOTARY_PROFILE=<profil> ./install.sh
```

Die App landet unter `/Applications/Poor Man's Text.app`. Die exakt gleiche,
ins Bundle eingebettete CLI wird über `/usr/local/bin/poormans-text` im
Terminalpfad verfügbar. Ein fremdes vorhandenes Ziel wird nicht überschrieben.
Der schnelle Testpfad `./install.sh --no-notarize` belässt die nur signierten
Artefakte zwingend im Repo-Root.

Der vollständige Lauf erzeugt außerdem `Poor-Mans-Text-<Version>.dmg` und eine
passende `.sha256`-Datei im Repo-Root. Wer die App aus diesem DMG nach
`/Applications` zieht, erhält beim ersten Start optional die Einrichtung der
eingebetteten CLI angeboten. Ein fremdes Kommandozeilenwerkzeug wird nie ersetzt;
Administratorrechte werden erst nach Zustimmung angefordert.

## Konvertierung

RTFD speichert den Text in `TXT.rtf` und Anhänge als separate Dateien innerhalb
eines macOS-Pakets. Poor Man's Text lässt das macOS-Textsystem daraus HTML und
die Anhänge erzeugen. Normales RTF speichert Bilder in der Datei; Pandoc liest
diesen Container und extrahiert die Medien ohne Cocoa-Zwischenschritt. DOCX und
ODT laufen durch einen gemeinsamen, abgeschotteten Pandoc-Containeradapter, der
jeden ZIP-Eintrag prüft und Medien nur im privaten Arbeitsbereich extrahiert. DOC
bleibt ein eigener Altformatadapter: macOS `textutil` erzeugt lokales HTML, und
der Konverter warnt vor möglichen Verlusten bei OLE-Objekten, Textfeldern, Makros
und manchen eingebetteten Inhalten. DOCX-Änderungen werden bewusst angenommen;
Kommentare und angenommene Änderungen erscheinen als Diagnosen.

Die formatneutrale Engine prüft den Quellinhalt, statt nur der Dateiendung zu
glauben, und wählt danach den passenden Weg. Alle Wege prüfen und ersetzen
Bildverweise, bevor Pandoc GitHub-Flavored Markdown erstellt.

Die Konvertierung läuft in einem privaten Staging-Verzeichnis. Erst nach
erfolgreichem Abschluss aller Stufen wird das Ergebnis an ein dauerhaftes oder
vom Aufrufer verwaltetes temporäres Ziel verschoben. Entfernte Bildverweise werden
nicht heruntergeladen, sondern abgelehnt. Anhänge, die nicht im Markdown
dargestellt werden können, erzeugen Warnungen.

## Formatunterstützung und Grenzen

In der Regel erhalten:

- Absätze und manuelle Zeilenumbrüche mit zwei Leerzeichen
- fette und kursive Schrift
- chromatischer RTFD-Text als `==Text==`-Markierung
- Hyperlinks
- einfache nummerierte Listen und Aufzählungen
- semantische Überschriften, Fußnoten und einfache Tabellen aus DOCX und ODT
- Reihenfolge und relative Verweise der Bilder

Erwartbare Verluste oder Annäherungen:

- Schriftfamilien, Grautöne, konkrete Farbwerte und genaue Schriftgrößen
- genaue Bildabmessungen
- Seitengeometrie und Absatzausrichtung
- komplexe Tabellen, Textfelder und mehrspaltige Anordnungen
- Gleichungen und anwendungsspezifische Rich-Text-Eigenschaften
- semantische Überschriftenebenen, wenn die Quelle nur größere Schrift verwendet
- DOCX-/ODT-Kommentare und DOC-Änderungsmarkup
- DOC-OLE-Objekte, Textfelder, Makros und von `textutil` nicht gelesene Bilder

## Entwicklung

```sh
./build.sh
swift test
./install.sh --no-notarize
```

Build-, Signatur- und Installationsdetails stehen in
[docs/BUILD-AND-TEST.md](docs/BUILD-AND-TEST.md). ODS, XLSX, XLS, Bilder, PDF und
ODM stehen in [ROADMAP.md](ROADMAP.md). Das geprüfte Workbook-Modell, beide
Tabellendarstellungen und die Mehrblatt-Entscheidung beschreibt
[docs/SPREADSHEET-IMPORT.md](docs/SPREADSHEET-IMPORT.md).

Die Tests erzeugen echte temporäre Cocoa-RTFD-Pakete und monolithische RTF-Dateien
mit Formatierungen, Farben, Leerzeilen, Links, Listen, Unicode-Dateinamen und
eingebetteten Bildern. Versionierte DOCX-, ODT- und binäre DOC-Fixtures aus
unabhängigen Erzeugern decken Überschriften, Fußnoten, Tabellen, Listen, Links,
Kommentare, Änderungen, Unicode und Medien-Hashes ab. Die Tests prüfen außerdem
vorhandene Ziele, defekte oder unsichere Pakete, die XLS-/DOC-Unterscheidung im
OLE-Container, fehlende Abhängigkeiten, Warnungen, den CLI-Link-Schutz und den
`NSItemProvider`-Drop-Pfad der App.

Die aktuelle Version ist 0.5.1.

## Lizenz

Poor Man's Text steht unter der **WTFPL**, Version 2
(Do What The Fuck You Want To Public License) — siehe [LICENSE](LICENSE).
Die Herkunft des App-Icons ist in [ASSETS.md](ASSETS.md) dokumentiert.

Pandoc ist eine externe Laufzeitabhängigkeit und wird nicht mit Poor Man's Text
ausgeliefert. Für Pandoc gilt seine eigene Lizenz.

Poor Man's Text verarbeitet Dokumente lokal und enthält weder Telemetrie noch
Netzwerkdienste. Einzelheiten stehen in [PRIVACY.md](PRIVACY.md), Hinweise zum
Support in [SUPPORT.md](SUPPORT.md).
