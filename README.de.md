<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="App-Icon von Poor Man's Text">
</p>

<h1 align="center">Poor Man's Text</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Dokumente, Tabellen, PDFs und Bilder in Markdown umwandeln.</strong>
</p>

Poor Man's Text wandelt RTF, RTFD, DOCX (einschließlich DOCM und DOTX/DOTM), ODT,
alte Word-Dateien (`.doc`), ODS, XLSX (einschließlich XLSM und XLTX/XLTM), XLS,
CSV und TSV, OpenDocument-Masterdokumente (`.odm`), PDFs, HTML und
Safari-Webarchive, EPUB, LaTeX, DocBook, Org, MediaWiki, Textile,
reStructuredText, FictionBook sowie PNG-, JPEG-, HEIC-, TIFF-, GIF-, BMP- und
WebP-Bilder in Ordner mit Markdown und gegebenenfalls separat gespeicherten
Bildern um.

Das Projekt stellt zwei Oberflächen für denselben Konvertierungskern bereit:

- `poormans-text`, ein automatisierbares Kommandozeilenwerkzeug
- eine native macOS-App zum Öffnen oder Ablegen unterstützter Dokumente, Tabellen, PDFs und Bilder

Die Konvertierung ist bewusst verlustbehaftet. Markdown kann Dokumentstruktur,
Links, einfache Hervorhebungen, Listen und Bilder bewahren, aber nicht jede
Schrift, Anordnung oder TextKit-spezifische Eigenschaft.

## Ausgabe

Die Konvertierung einer unterstützten Eingabe erzeugt einen neuen Nachbarordner,
ohne die Quelle zu verändern. Enthält die Eingabe extrahierbare Bilder, sieht das
Ergebnis so aus:

```text
Dokument-markdown/
├── Dokument.md
└── images/
    ├── image01.png
    └── image02.jpg
```

Die Bildverweise in `Dokument.md` sind relativ und stehen an derselben
Textposition wie im Ausgangsdokument. Extrahierte Bilder erhalten stabile,
fortlaufende Namen statt technischer Anhangsnamen aus dem Quelldokument.
Vorhandene Ausgabeordner werden nie
überschrieben.

Manuelle Zeilenumbrüche enden im Markdown mit zwei Leerzeichen. Chromatischer
Text aus RTFD wird als `==Text==` markiert. Diese von Fastra unterstützte
Schreibweise ist eine verbreitete Markdown-Erweiterung, gehört aber nicht zum
GFM-Standard; der konkrete Farbwert bleibt dabei nicht erhalten. Im bildsicheren
RTF-Import lassen sich Farbinformationen nicht erhalten; der Text bleibt erhalten
und der Konverter meldet den Verlust als Warnung.

## Voraussetzungen

- macOS 13 oder neuer
- [Pandoc](https://pandoc.org/installing.html) für Textdokumente und ODM
- Swift 6.2 oder neuer für den Bau aus dem Quellcode

ODS, XLSX, XLS, CSV, TSV, PDF und Bilder werden nativ gelesen und brauchen kein
externes Konvertierungswerkzeug. Für die übrigen Formate sucht der Konverter Pandoc in
den üblichen Homebrew-Verzeichnissen und danach über `PATH`. Dem CLI kann mit
`--pandoc PFAD` auch ein bestimmtes Programm übergeben werden.

Solange Pandoc fehlt, bietet die App bei jedem Start an, es über Homebrew zu
installieren; ohne Homebrew verweist sie auf die offizielle
Installationsanleitung. Das Angebot endet, sobald Pandoc vorhanden ist oder
„Don't Ask Again" gewählt wurde.

## Download

DMG und zugehörige `.sha256`-Datei stehen im
[neuesten GitHub-Release](../../releases/latest). Liegen beide Dateien im selben
Ordner, lässt sich der Download vor dem Öffnen prüfen:

```sh
shasum -a 256 -c Poor-Mans-Text-0.9.1.dmg.sha256
```

Danach das DMG öffnen und Poor Man's Text in den Programme-Ordner ziehen. Die
App ist mit Developer ID signiert, von Apple notarisiert und enthält die passende
universelle CLI. Pandoc bleibt für Textdokumente und ODM eine getrennte
Voraussetzung und lässt sich beispielsweise mit `brew install pandoc`
installieren.

## Updates

Ab 0.7.0 hält sich die App über Sparkle selbst aktuell. Sie prüft selbsttätig
einen signierten Update-Feed und bietet im Programmmenü „Check for Updates …";
geladen und installiert wird nichts ohne Zustimmung. Feed und Image müssen eine
gültige Ed25519-Signatur tragen, und die neue Fassung wird vor dem Entpacken
geprüft. Version 0.6.0 und älter haben noch keinen Updater — 0.7.0 muss deshalb
einmal von Hand aus dem DMG installiert werden.

Ein Profil des Macs überträgt die App bei der Suche nicht. Was GitHub als
Betreiber von Feed und Download erhält, steht in [PRIVACY.md](PRIVACY.md),
zusammen mit dem Terminal-Befehl, der die selbsttätige Suche abschaltet.

## Kommandozeile

```sh
poormans-text Dokument.rtfd
poormans-text Dokument.rtf
poormans-text Dokument.docx
poormans-text Dokument.odt
poormans-text Dokument.doc
poormans-text Arbeitsmappe.ods
poormans-text Arbeitsmappe.xlsx
poormans-text Arbeitsmappe.xls
poormans-text Buch.odm
poormans-text Dokument.pdf
poormans-text Scan.heic
poormans-text --image-ocr off Foto.jpg
poormans-text --spreadsheet-format tsv Arbeitsmappe.ods
poormans-text --output Konvertiert Dokument.rtfd
poormans-text --json Dokument.rtfd
poormans-text Bericht.docx Budget.xlsx Scan.pdf
poormans-text --output Konvertiert Dokumente/
poormans-text --frontmatter Bericht.docx
poormans-text --textbundle Bericht.docx
poormans-text --stdout Bericht.docx | pbcopy
```

Standardmäßig entsteht `Dokument-markdown` neben der Quelle. Alle Optionen zeigt
`poormans-text --help`. Ohne Installation funktionieren dieselben Aufrufe im
Quellcode-Verzeichnis als `swift run poormans-text …`.

Mehrere Eingaben oder ein Ordner werden nacheinander umgewandelt; ein Fehler
hält die übrigen Dokumente nicht auf. Ein nicht vorhandener Pfad oder ein
Ordner ohne bekannte Dokumente ist dagegen ein Argumentfehler: Der Lauf
endet, bevor etwas umgewandelt wird. Ein Ordner wird rekursiv nach bekannten
Dateiendungen durchsucht. Pakete wie `.rtfd` zählen als ein Dokument;
versteckte Einträge, symbolische Links und frühere `*-markdown`-Ergebnisse
werden übergangen. Mit `--output` wird das Verzeichnis zum Elternordner, der je
Dokument einen Ordner `Name-markdown` erhält und die Ordnerstruktur spiegelt.
`--json` liefert dann `{"ok", "version", "results": [...]}` mit einem Eintrag je
Eingabe, und der Exit-Code ist der der ersten fehlgeschlagenen Eingabe. Eine
einzelne Datei behält die bisherige Einzelantwort unverändert. Zwei Dokumente,
die sich nur in der Endung unterscheiden, etwa `Bericht.docx` und
`Bericht.odt`, teilen sich den Namen `Bericht-markdown`; das zweite wird als
Kollision am Ausgabeziel gemeldet, und nichts wird überschrieben.

### Frontmatter, Textbundle und Standardausgabe

`--frontmatter` stellt dem Markdown einen YAML-Kopf aus der Quelle voran:
Titel, Autor, Thema, Beschreibung, Schlüsselwörter sowie Erstell- und
Änderungsdatum, gelesen aus den OOXML-Kerneigenschaften (DOCX, XLSX), der
OpenDocument-Datei `meta.xml` (ODT, ODS, ODM), der RTF-Gruppe `\info` (RTF,
RTFD) oder dem PDF-Informationswörterbuch. Jeder Wert steht in
Anführungszeichen, Daten sind ISO 8601 in UTC. Eine Quelle ohne solche Angaben
bekommt eine Warnung statt eines leeren Kopfs. Dieselben Felder stehen als
`metadata` in jeder `--json`-Antwort, auch ohne den Schalter.

`--textbundle` schreibt `Bericht.textbundle` statt `Bericht-markdown`: Das
Markdown heißt `text.md`, Bilder liegen unter `assets/`, und `info.json`
kennzeichnet das Paket, sodass Bear, iA Writer und Ulysses es direkt öffnen.
Mit `--output` muss der Name auf `.textbundle` enden. Die Ordnersuche übergeht
vorhandene Bundles.

`--stdout` wandelt genau ein Dokument an einem temporären Ort um, gibt das
Markdown auf der Standardausgabe aus und entfernt das temporäre Ergebnis.
Diagnosen gehen an die Standardfehlerausgabe. Bilder werden nicht behalten und
gemeldet; ihre Verweise bleiben im Text. Der Schalter lässt sich nicht mit
`--json`, `--output`, `--textbundle`, mehreren Eingaben oder einem Ordner
kombinieren.

Die Exit-Codes folgen den üblichen `sysexits`-Werten: `64` für Aufruffehler,
`65` für ungültige Eingabedaten, `66` für eine fehlende Eingabe, `69` für ein
fehlendes Pandoc, `70` für einen fehlgeschlagenen Konvertierungsprozess, `73`
für eine Kollision am Ausgabeziel und `74` für einen Dateisystemfehler. Mit
`--json` werden Erfolge und Fehler als JSON auf der Standardausgabe gemeldet;
andernfalls gehen Diagnosen an die Standardfehlerausgabe. Eingaben werden als
Dateisystempfade und nicht über die Standardeingabe entgegengenommen.

### Unterstützte Formate abfragen

```sh
poormans-text --formats
poormans-text --formats --json
```

`--formats` fasst kein Dokument an und endet immer mit `0`. Die Ausgabe nennt
jedes Format, das dieser Stand lesen kann, seine Dateiendungen, ob die Quelle
eine einzelne Datei oder ein Ordner-Paket wie `.rtfd` ist, welche externen
Werkzeuge nötig sind und ob diese gerade installiert sind:

```text
rtf         .rtf                                              file     pandoc           available
rtfd        .rtfd                                             package  pandoc+textutil  available
docx        .docx .docm .dotx .dotm                           file     pandoc           available
odt         .odt                                              file     pandoc           available
doc         .doc                                              file     textutil+pandoc  available
ods         .ods                                              file                      available
xlsx        .xlsx .xlsm .xltx .xltm                           file                      available
xls         .xls                                              file                      available
odm         .odm                                              file     pandoc           available
image       .png .jpg .jpeg .heic .tif .tiff .gif .bmp .webp  file                      available
pdf         .pdf                                              file                      available
csv         .csv .tsv                                         file                      available
html        .html .htm .xhtml                                 file     pandoc           available
webarchive  .webarchive                                       file     pandoc           available
epub        .epub                                             file     pandoc           available
latex       .tex .latex                                       file     pandoc           available
docbook     .dbk .docbook                                     file     pandoc           available
org         .org                                              file     pandoc           available
mediawiki   .wiki .mediawiki                                  file     pandoc           available
textile     .textile                                          file     pandoc           available
rst         .rst                                              file     pandoc           available
fb2         .fb2                                              file     pandoc           available
```

Fehlt Pandoc, steht bei Textdokumenten, ODM, HTML, E-Books und den
Textauszeichnungen `unavailable (missing required tool: pandoc)`; ODS, XLSX,
XLS, CSV, TSV, PDF und Bilder bleiben verfügbar. Das für DOC und RTFD zusätzlich nötige `textutil` gehört zu macOS.

So entscheidet eine andere App, ob sie eine Umwandlung anbietet. Weil die Liste
aus dem Konverter selbst stammt, übernimmt ein Aufrufer später hinzukommende
Formate, ohne selbst geändert zu werden. Die Endungen sind dabei nur ein
schneller Vorfilter — die Umwandlung erkennt das Format immer erneut am Inhalt
und meldet einen ehrlichen Fehler, wenn beides nicht zusammenpasst.

## macOS-App

App und CLI lassen sich vom Repo-Root bauen:

```sh
./build.sh
open "Poor Man's Text.app"
```

`./build.sh` erzeugt das Bundle unter `.build/app/` und legt es zusammen mit der
CLI zusätzlich im Repo-Root ab. Beide Kopien sind nur für lokale Tests
ad-hoc-signiert: Sie sind kein notarisierter Distributions-Build und gehören
nicht nach `/Applications`.

Beliebig viele unterstützte Dokumente, Tabellen, PDFs, Bilder oder Ordner
können in das Fenster oder auf die App gezogen oder über den Dateidialog
ausgewählt werden. Ein Ordner wird nach denselben Regeln wie auf der
Kommandozeile durchsucht, und jedes Ergebnis entsteht neben seiner Quelle. Die
App zeigt den Ausgang je Dokument und kann die erzeugten Markdown-Dateien im
Finder anzeigen.

Die App meldet außerdem zwei Systemdienste an, die nach dem ersten Start zur
Verfügung stehen (macOS führt sie unter Systemeinstellungen › Tastatur ›
Tastaturkurzbefehle › Dienste):

- **Convert to Markdown with Poor Man's Text** erscheint im Kontextmenü des
  Finders für unterstützte Dokumente und Ordner. Der Dienst übergibt die Auswahl
  an die App, die alles neben seiner Quelle umwandelt, genau wie beim Ablegen.
- **Convert Text to Markdown with Poor Man's Text** erscheint im Untermenü
  „Dienste" jeder App, die markierten Rich Text anbietet, etwa Mail, Pages,
  TextEdit oder Safari. Das Markdown landet in der Zwischenablage und kann
  eingefügt werden; in der Quell-App wird nichts ersetzt. Bilder in der Auswahl
  bleiben außen vor und werden gemeldet, weil die Zwischenablage nur Text
  trägt. Eine Auswahl, die nur RTF anbietet, braucht Pandoc wie eine
  `.rtf`-Datei.

## Signierte Installation

Der Installer baut App und CLI als Universal Binaries, signiert beide mit
Developer ID und Hardened Runtime, notarisiert und stapelt die App und
installiert erst danach das geprüfte Bundle:

```sh
NOTARY_PROFILE=<profil> ./install.sh
```

Die App landet unter `/Applications/Poor Man's Text.app`. Die exakt gleiche,
ins Bundle eingebettete CLI wird als `poormans-text` im Terminalpfad
verfügbar. Der Installer behält das Verzeichnis einer bereits installierten
Fassung und nimmt sonst das erste Homebrew-`bin` im `PATH`; `CLI_INSTALL_DIR`
setzt es außer Kraft. Ein fremdes vorhandenes Ziel wird nicht überschrieben.
Der schnelle Testpfad `./install.sh --no-notarize` belässt die nur signierten
Artefakte zwingend im Repo-Root.

## Release-DMG

Das Distributions-DMG baut ein eigener Einstiegspunkt, der bewusst nichts
installiert:

```sh
NOTARY_PROFILE=<profil> ./release.sh
```

Er durchläuft denselben Bau-, Signatur- und Notarisierungsweg, erzeugt danach
das signierte DMG, notarisiert und stapelt auch dieses und legt am Ende
`Poor-Mans-Text-<Version>.dmg` samt passender `.sha256`-Datei im Repo-Root ab.
Vorhandene Artefakte werden nie überschrieben: Existiert das Paar dieser Version
bereits, bricht der Lauf ab.

Ein vollständiges Release — DMG, Checksumme und die geprüfte Installation aus
genau demselben signierten Bundle — ist dagegen ein einziger Lauf:

```sh
NOTARY_PROFILE=<profil> ./install.sh --with-dmg
```

Wer die App aus dem DMG nach `/Applications` zieht, erhält beim ersten Start
optional die Einrichtung der eingebetteten CLI angeboten. Ein fremdes
Kommandozeilenwerkzeug wird nie ersetzt; Administratorrechte werden erst nach
Zustimmung angefordert.

## Konvertierung

RTFD speichert den Text in `TXT.rtf` und Anhänge als separate Dateien innerhalb
eines macOS-Pakets. Poor Man's Text lässt das macOS-Textsystem daraus HTML und
die Anhänge erzeugen. Normales RTF speichert Bilder in der Datei; Pandoc liest
diesen Container und extrahiert die Medien ohne Cocoa-Zwischenschritt. DOCX,
DOCM, DOTX/DOTM und ODT laufen durch einen gemeinsamen, abgeschotteten
Pandoc-Containeradapter, der jeden ZIP-Eintrag prüft und Medien nur im privaten
Arbeitsbereich extrahiert. Makrofähige Pakete und Vorlagen werden nach Prüfung
ihres OOXML-Inhaltstyps angenommen. Eigene Warnungen weisen darauf hin, dass
Makros und Vorlagenverhalten nicht erhalten bleiben.

DOC bleibt ein eigener Altformatadapter: macOS `textutil` erzeugt lokales HTML, und
der Konverter warnt vor möglichen Verlusten bei OLE-Objekten, Textfeldern, Makros
und manchen eingebetteten Inhalten. DOCX-Änderungen werden bewusst angenommen;
Kommentare und angenommene Änderungen erscheinen als Diagnosen.

ODS, XLSX und binäres XLS verwenden native Leser und ein gemeinsames
Arbeitsmappenmodell. Jedes Blatt wird in Quellreihenfolge zu einem
Markdown-Abschnitt, wahlweise als GFM-Tabelle oder als maskierter TSV-Codeblock.
Formeln werden nicht berechnet; ausgegeben werden die gespeicherten Zellwerte.
ODM-Masterdokumente behalten ihren eigenen Text und lösen nur
vorhandene lokale ODT-Abschnitte sicher auf, bevor sie diese in Quellreihenfolge
zusammenführen.

PDFKit liest eingebetteten PDF-Text. Seiten mit weniger als 20 extrahierten
Zeichen rendert der Konverter lokal und liest sie mit Vision-OCR; das Markdown
behält sichtbare Seitenabschnitte. Passwortgeschützte PDFs, mehr als 1.000 Seiten
und OCR-Arbeit über dem 64-Millionen-Pixel-Budget werden vor der Veröffentlichung
abgelehnt. Weder PDFKit noch Vision öffnen entfernte Inhalte.

CSV und TSV werden zu einer Ein-Blatt-Mappe, die wie ODS oder XLSX gerendert
wird. Die Endung entscheidet über das Format, weil reiner Text am Inhalt nicht
als Tabelle erkennbar ist; `.tsv` trennt an Tabulatoren, `.csv` wählt das
Trennzeichen, das in den ersten Zeilen am gleichmäßigsten vorkommt. Eine
Byte-Order-Mark wählt UTF-8 oder UTF-16, Text ohne gültiges UTF-8 wird als
Windows-1252 mit Warnung gelesen, Binärinhalt wird abgelehnt.

HTML, Safari-Webarchive, EPUB, LaTeX, DocBook, Org, MediaWiki, Textile,
reStructuredText und FictionBook laufen durch Pandoc im Sandbox-Modus, der
auch `\input` in LaTeX daran hindert, fremde Dateien zu lesen. HTML wird am
Inhalt erkannt; die Textauszeichnungen brauchen ihre Endung, und eine
`.xml`-Datei gilt nur mit DocBook-Namensraum als DocBook. Bilder neben der
Quelle werden übernommen, wenn sie unterhalb des Quellordners liegen;
eingebettete `data:`-Bilder werden ausgepackt; entfernte Bilder werden nie
geladen und bleiben als Link; fehlende Bilder fallen weg und hinterlassen ihren
Alt-Text. Webarchive nutzen ihre eigenen gespeicherten Bilder. Skripte, Styles,
Formulare und Seitenlayout werden nicht abgebildet, ein EPUB wird zu einer
Markdown-Datei zusammengeführt.

Der Bildimport übernimmt PNG, JPEG, HEIC, TIFF, GIF, BMP und WebP unverändert als Asset unter
`images/` und verlinkt es relativ aus dem Markdown. Standardmäßig ergänzt Vision
darunter lokal erkannten Text. `--image-ocr off` behält nur das Bild; das eignet
sich etwa für Handschrift, Diagramme oder Text, der nicht als Markdown suchbar
werden soll. Die macOS-App bietet dieselbe Auswahl vor der Umwandlung. Ein mehrseitiges TIFF bleibt ein Asset und erhält einen OCR-Abschnitt
pro Frame. Für Bilder gelten dieselben OCR-Grenzen wie beim PDF-Fallback:
höchstens 16 Millionen Pixel pro Frame und 64 Millionen insgesamt. Der Konverter
markiert unsichere OCR-Stellen im Markdown, damit sie am Original geprüft werden.

Die formatneutrale Engine prüft den Quellinhalt, statt nur der Dateiendung zu
glauben, und wählt danach den passenden Weg. Bei Textdokumenten werden
Bildverweise geprüft und ersetzt, bevor Pandoc GitHub-Flavored Markdown erstellt;
die nativen Tabellenleser starten Pandoc nicht.

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
- Hyperlinks in Textdokumenten
- einfache nummerierte Listen und Aufzählungen
- semantische Überschriften, Fußnoten und einfache Tabellen aus DOCX und ODT
- Reihenfolge und relative Verweise der Bilder
- gespeicherte Tabellenwerte, Blattnamen, Blattreihenfolge, leere Zellen, interne Umbrüche
  und je Zelle ein Linkziel
- Reihenfolge lokaler ODM-Abschnitte
- eingebetteter PDF-Text in Seitenreihenfolge mit Seitenabschnitten
- bytegleiche PNG-, JPEG-, HEIC- und TIFF-Assets mit optional lokal erkanntem Text

Erwartbare Verluste oder Annäherungen:

- Schriftfamilien, Grautöne, konkrete Farbwerte und genaue Schriftgrößen
- genaue Bildabmessungen
- Seitengeometrie und Absatzausrichtung
- komplexe Tabellen, Textfelder und mehrspaltige Anordnungen
- Gleichungen und anwendungsspezifische Rich-Text-Eigenschaften
- semantische Überschriftenebenen, wenn die Quelle nur größere Schrift verwendet
- DOCX-/ODT-Kommentare und DOC-Änderungsmarkup
- DOC-OLE-Objekte, Textfelder, Makros und von `textutil` nicht gelesene Bilder
- DOCM-/DOTM-Makros und das Vorlagenverhalten von DOTX/DOTM
- Tabellenformeln ohne gespeichertes Ergebnis, Zellverbünde, Diagramme,
  Zeichnungen, Kommentare, Makros und genaue Formatierung
- mehrere unterschiedliche Linkziele in einer Tabellenzelle; das erste Ziel und
  der gesamte sichtbare Text bleiben, das weitere Ziel wird als Warnung gemeldet
- ODM-Abschnittsgrenzen und Masterdokumentverhalten nach dem Zusammenführen
- PDF-Seitenlayout, Spalten, Tabellen, Kopf- und Fußzeilen sowie genaue
  Textpositionen; lokale OCR kann Erkennungsfehler enthalten und braucht Prüfung
- OCR-Lesereihenfolge und genaues Layout von Bildern; das erhaltene Originalbild
  bleibt die maßgebliche Quelle zur Prüfung

## Entwicklung

```sh
./build.sh
swift test
./install.sh --no-notarize
```

Build-, Signatur- und Installationsdetails stehen in
[docs/BUILD-AND-TEST.md](docs/BUILD-AND-TEST.md). Den Bildimport beschreibt
[docs/IMAGE-IMPORT.md](docs/IMAGE-IMPORT.md); den PDF-Import beschreibt
[docs/PDF-IMPORT.md](docs/PDF-IMPORT.md). Das implementierte Arbeitsmappenmodell, beide
Tabellendarstellungen und das Mehrblattverhalten beschreibt
[docs/SPREADSHEET-IMPORT.md](docs/SPREADSHEET-IMPORT.md).

Die Tests erzeugen echte temporäre Cocoa-RTFD-Pakete und monolithische RTF-Dateien
mit Formatierungen, Farben, Leerzeilen, Links, Listen, Unicode-Dateinamen und
eingebetteten Bildern. Versionierte DOCX-, ODT- und binäre DOC-Fixtures aus
unabhängigen Erzeugern decken Überschriften, Fußnoten, Tabellen, Listen, Links,
Kommentare, Änderungen, Unicode und Medien-Hashes ab. Native Tabellentests
decken echte ODS- und XLS-Dateien, erzeugte XLSX-Pakete, Blattreihenfolge,
Zellbudgets, Linkziele, Warnungen und einen unabhängigen Pandoc-Vergleich ab. ODM-Tests
verwenden lokal verknüpfte ODT-Dateien. Die Tests erzeugen außerdem echte
temporäre PDFs mit eingebettetem Text, leeren OCR-Seiten, Verschlüsselung sowie
Seiten- und Pixelbudgets. Bildtests erzeugen PNG- und mehrseitige TIFF-Fixtures,
vergleichen die erhaltenen Asset-Bytes und prüfen beide OCR-Modi. Sie prüfen
außerdem vorhandene Ziele, defekte oder unsichere Pakete, fehlende Abhängigkeiten, den
CLI-Link-Schutz und den `NSItemProvider`-Drop-Pfad der App.

Die aktuelle Version ist 0.9.1.

## Lizenz

Poor Man's Text steht unter der **WTFPL**, Version 2
(Do What The Fuck You Want To Public License) — siehe [LICENSE](LICENSE).
Die Herkunft des App-Icons ist in [ASSETS.md](ASSETS.md) dokumentiert.

Pandoc ist eine externe Laufzeitabhängigkeit und wird nicht mit Poor Man's Text
ausgeliefert. Für Pandoc gilt seine eigene Lizenz.

Der Updater [Sparkle](https://sparkle-project.org) wird mitgeliefert; für ihn
gilt seine eigene Lizenz, die als `Contents/Resources/Sparkle-LICENSE.txt` in
der App liegt.

Poor Man's Text verarbeitet Dokumente lokal und enthält keine Telemetrie. Der
einzige Netzwerkzugriff ist die Update-Suche. Einzelheiten stehen in
[PRIVACY.md](PRIVACY.md), Hinweise zum Support in [SUPPORT.md](SUPPORT.md).
