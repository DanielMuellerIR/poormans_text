<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="App-Symbol von Poor Man's Text">
</p>

# Poor Man’s Text

[English](README.md) · [Deutsch](README.de.md)

Wandle Dokumente in Markdown um und lies Felder aus PDF-Rechnungen und
Lieferscheinen als JSON aus. Poor Man’s Text enthält eine Desktop-App und das
Kommandozeilenprogramm `poormans-text` für macOS und Linux.

## Download und Installation

Die [neueste Veröffentlichung](../../releases/latest) enthält ein notarisiertes
Universal-DMG für macOS ab Version 13 sowie Linux-Pakete und portable Archive
für x86-64. Lade die gewünschte Datei und die zugehörige `.sha256`-Datei herunter.

**macOS.** Prüfe den Download mit
`shasum -a 256 -c Poor-Mans-Text-0.41.26.dmg.sha256`. Öffne das DMG und ziehe die
App in den Programme-Ordner. Die App kann das mitgelieferte Kommandozeilenprogramm
in einem Verzeichnis auf `PATH` verlinken. Pandoc gibt es als
[offizielles Installationspaket](https://pandoc.org/installing.html) und über
Homebrew. Falls Pandoc fehlt, bietet die App beim Start Hilfe zur Installation an.

**Linux.** Prüfe den Download mit `sha256sum -c`. Installiere das DEB mit
`sudo apt install ./poormans-text_0.41.26-1_amd64.deb` oder das Arch-Paket mit
`sudo pacman -U ./poormans-text-0.41.26-1-x86_64.pkg.tar.zst`. Im entpackten
portablen Archiv startet `usr/bin/poormans-text-app` die GTK-App und
`usr/bin/poormans-text` die CLI. [Linux-Abhängigkeiten und Installation](docs/LINUX-BUILD.md)

`poormans-text --formats` zeigt die auf deinem System verfügbaren Importe.
Pandoc liest Formate wie DOCX, ODT, RTF, HTML und EPUB. Tabellen und
Präsentationen liest der gemeinsame Kern direkt. PDF, Bilder und alte
Word-Dateien verwenden die im Formatkatalog aufgeführten Plattformwerkzeuge.

Die macOS-App prüft über Sparkle einen signierten Update-Feed. Download und
Installation bestätigst du in der App. [Datenschutz und Update-Einstellungen](PRIVACY.md)

## Dokument umwandeln

Ziehe eine Datei oder einen Ordner in die App oder klicke auf **Dokument auswählen**.
Zielordner und Konvertierungsoptionen kannst du vor dem Start einstellen.
Das Ergebnis lässt sich im Standardeditor für Markdown oder direkt in Fastra
öffnen, falls Fastra installiert ist. Auf macOS kannst du auch über den
Finder-Dienst und die Kurzbefehle-Aktionen konvertieren.

Im Terminal:

```sh
poormans-text Bericht.docx
poormans-text --output ./Konvertiert --jobs 2 ./Quelldateien
poormans-text --textbundle Praesentation.pptx
poormans-text --stdout Tabelle.csv
```

Für eine einzelne Eingabe entsteht üblicherweise ein Ordner wie
`Bericht-markdown/Bericht.md` neben der Quelle. Bilder und Anhänge werden neben
dem Markdown abgelegt. Ordner werden nach unterstützten Dateien durchsucht.
Der Stapellauf bildet die Unterordner im Ziel ab. Jedes Ergebnis wird erst
nach vollständiger Konvertierung veröffentlicht. Originaldateien und vorhandene
Ergebnisordner bleiben erhalten.

Textbundle fasst Markdown und Assets in einem Paket zusammen. `--frontmatter`
übernimmt verfügbare Dokumentmetadaten. `--stdout` gibt das Markdown eines
einzelnen Dokuments aus. Wähle einen Ordner oder Textbundle für Ergebnisse mit
Bild- und Anhangsdateien oder mehreren Dokumenten.

## Unterstützte Eingaben

| Eingabe | Formate |
| --- | --- |
| Textverarbeitung | RTF, RTFD, DOCX, DOCM, DOTX, DOTM, ODT, altes DOC, ODM |
| Tabellen | ODS, XLSX, XLSM, XLTX, XLTM, XLS, CSV, TSV |
| Folien und Notebooks | PPTX, PPTM, POTX, ODP, IPYNB |
| PDF und Bilder | PDF, PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP |
| Web und Textformate | HTML, Safari-Webarchive, EPUB, LaTeX, DocBook, Org, MediaWiki, Textile, reStructuredText, FictionBook |
| Mail und Notizen | EML, EMLX, Outlook MSG, MBOX und Apple-Mail-Exporte, Evernote ENEX |

Markdown erhält Text und Strukturen wie Überschriften, Listen, einfache
Hervorhebung, Links und Bilder. Seitenlayout, Schriften und manche Funktionen
des Quellformats lassen sich nur näherungsweise abbilden. Diagnosen machen
bekannte Verluste, Ersatzwege und nicht unterstützte Inhalte sichtbar. Der
Notebook-Import behandelt Inhalte als Daten. Die Konvertierung verwendet
lokale Ressourcen. Links in der Vorschau sind inaktiv.

- [DOCX-Kommentare und Änderungsverfolgung](docs/DOCX-REVIEWS.md)
- [PDF-Text, Seitenauswahl und OCR](docs/PDF-IMPORT.md) · [Strukturierte OCR](docs/STRUCTURED-OCR.md)
- [Bildimport](docs/IMAGE-IMPORT.md) · [Import aus der Zwischenablage](docs/CLIPBOARD-IMPORT.md)
- [Tabellen](docs/SPREADSHEET-IMPORT.md) · [Präsentationen](docs/PRESENTATION-IMPORT.md) · [Notebooks](docs/NOTEBOOK-IMPORT.md)
- [Dokumentensammlungen](docs/COLLECTIONS.md) · [MBOX](docs/MBOX.md) · [ENEX](docs/ENEX.md)

## Inhalte auswählen und Einstellungen speichern

Mit **Inhalte auswählen** kannst du vor der Konvertierung PDF-Seiten,
Tabellenblätter, Folien oder EPUB-Kapitel ansehen. Die CLI unterstützt
`--pdf-pages 2-4`, `--sheet-name Budget`, `--slides 1,3-5` und
`--epub-chapters 2,4`. Die Detailseiten erklären
[Blätter und Zellbereiche](docs/SPREADSHEET-SELECTION.md),
[Präsentationsfolien](docs/PRESENTATION-SELECTION.md) und [EPUB-Kapitel](docs/EPUB-SELECTION.md).

Wiederkehrende Einstellungen lassen sich als benanntes Profil in der App oder
mit `poormans-text --save-profile NAME` speichern. `--profile NAME` wendet das
Profil an. Einzelne CLI-Optionen haben Vorrang. Die Kurzbefehle-Aktion
**Dokument mit Profil umwandeln** bietet **Profilwert**, **Ein** und **Aus**.
[Profile, portables JSON und quellgebundene Auswahl](docs/PROFILES.md)

## Vorschau, Vergleich und Automatisierung

Die App zeigt gerendertes Markdown, den Markdown-Quelltext und unterstützte
lokale Assets an. **Vergleichen** prüft Quelle und Ergebnis anhand ihrer
Fingerabdrücke, bevor es aufgezeichnete Positionen verwendet. PDF-Seiten und
Bildframes lassen sich separat betrachten.
[Markdown-Vorschau](docs/MARKDOWN-PREVIEW.md) · [Quellenvergleich](docs/SOURCE-COMPARISON.md)

`--json` gibt das Ergebnis maschinenlesbar aus. `--source-map` erfasst verfügbare
Quellpositionen, `--report` speichert den Diagnosebericht im Ausgabeordner.
`--formats --json` liefert den Formatkatalog. `--help` zeigt die verfügbaren
CLI-Optionen. [Berichte](docs/CONVERSION-REPORT.md) · [Diagnosen](docs/DIAGNOSTICS.md) · [CLI-Vertrag für Fastra und andere Aufrufer](docs/FASTRA-CONTRACT.md)

## Belegdaten auslesen

Erstelle mit **Belegdaten auslesen** eine JSON-Maske für PDFs mit gleichartigem
Layout. Wähle zum Beispiel Rechnungsnummer und Lieferdatum und prüfe die
gefundenen Wörter anhand ihrer Position auf der Seite. **Maske anwenden**
überträgt eine vorhandene Maske auf mehrere PDFs.

```sh
poormans-text extract --mask rechnungsmaske.json --output-dir Ergebnisse Rechnung-4711.pdf Rechnung-4712.pdf
```

Editor und CLI verwenden auf beiden Betriebssystemen dieselben Masken. Die
Extraktion liest eingebetteten PDF-Text und markiert fehlende oder mehrdeutige
Felder zur Prüfung. [Belegmasken, manuelle Korrekturen und Stapel-JSON](docs/RECEIPT-EXTRACTION.md)

## Bauen und testen

Für den Quellcode ist Swift ab Version 6.2 nötig. Der GTK-Build auf Linux
braucht zusätzlich Rust und die GTK-Entwicklungspakete.

```sh
swift test
./build.sh
```

[macOS-Build und Tests](docs/BUILD-AND-TEST.md) · [Linux-Build und Paketierung](docs/LINUX-BUILD.md) · [Architektur](docs/ARCHITECTURE.md)

Quellversion **0.41.26**. [Versionshinweise](docs/releases/0.41.26.md) · [Änderungsprotokoll](CHANGELOG.md)

## Lizenz

**WTFPL**, Version 2. [LICENSE](LICENSE) enthält die Projektlizenz und Hinweise
zu Abhängigkeiten.
