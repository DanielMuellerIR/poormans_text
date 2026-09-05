# Poor Man's Text — Roadmap

Hier steht nur offene Produktarbeit und bewusst gesetzte Formatgrenzen.
Erledigte Punkte werden beim Release aus dieser Datei entfernt und in
[CHANGELOG.md](CHANGELOG.md) festgehalten.

Die formatneutrale Engine, sichere Inhaltserkennung und wählbare dauerhafte oder
temporäre Veröffentlichung sind vorhanden. RTF, RTFD, DOCX/DOCM/DOTX/DOTM,
ODT, DOC, ODS, XLSX/XLSM/XLTX/XLTM, XLS, CSV/TSV, ODM, PDF, HTML, Webarchive,
EPUB, LaTeX, DocBook, Org, MediaWiki, Textile, reStructuredText, FictionBook
sowie PNG, JPEG, HEIC, TIFF, GIF, BMP und WebP sind implementiert. Ihre Importwege stehen in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Etappenplan (Stand 2026-09-02)

Die Etappen sind nach Nutzen je Aufwand sortiert und bauen aufeinander auf.
Jede Etappe ist für sich releasefähig. Ein neuer Adapter meldet sich weiterhin
nur über `supportedFormatDescriptors`; der Orchestrator bleibt unverändert.
Was [docs/MARKITDOWN-COMPARISON.md](docs/MARKITDOWN-COMPARISON.md) vorschlägt,
ist hier eingeordnet. Die Etappen 1 (mehrere Eingaben und Ordner), 2 (Dienste,
bis auf App Intents), 3 (`--stdout`, `--frontmatter`, `--textbundle`) und 4
(kleine Formatgewinne) sind umgesetzt und stehen bis zum nächsten Release im Changelog unter „Unreleased“.

### Etappe 2 — Systemintegration ohne Terminal

Die beiden Systemdienste (Finder-Kontextmenü für Dateien, markierter Rich Text
in die Zwischenablage) sind umgesetzt; offen bleibt:

- Kurzbefehle-Aktion „Dokument in Markdown umwandeln“ über App Intents
  (macOS 13+), mit denselben Optionen wie die CLI. **Blocker (2026-09-02):**
  Kurzbefehle findet eine Aktion nur über das Bundle `Metadata.appintents`,
  das Xcodes `appintentsmetadataprocessor` aus `.swiftconstvalues`-Dateien des
  Compilers erzeugt. Der SwiftPM-Build in `scripts/build_app.sh` erzeugt beides
  nicht; nötig wären `-emit-const-values-path` samt Apples
  Protokollliste je Übersetzungseinheit und ein eigener Prozessor-Aufruf pro
  Architektur. Erst angehen, wenn der Aufwand den Nutzen gegenüber „Shell-Skript
  ausführen“ mit `poormans-text --json` in Kurzbefehle rechtfertigt.

### Etappe 5 — Präsentationen und Notebooks

- PPTX/PPTM/POTX nativ: ZIP-Inspector und XML-Streaming wie beim
  Tabellenimport. Eine Überschrift je Folie, Text-Shapes als Absätze und Listen,
  Tabellen als GFM-Tabellen, Notizen als Blockzitat, Bilder aus `ppt/media`
  über die Asset-Pipeline. Pandoc liest keine Präsentationen.
- ODP über dasselbe Folienmodell mit dem OpenDocument-Parser.
- IPYNB: Markdown-Zellen durchreichen, Code-Zellen als Fenced Blocks mit
  Sprache aus den Metadaten, Textausgaben als Ausgabe-Fences, Base64-Bilder aus
  Ausgaben nach `images/`.

### Etappe 6 — E-Mail

- EML und `.emlx` (Apple Mail): Kopfzeilen als Tabelle oder Frontmatter, der
  HTML- oder Textkörper durch den Rewriter, Anhänge nach `attachments/`.
- MSG (Outlook) über den eigenständigen OLE-Containerleser.

### Etappe 7 — Qualität des PDF-Imports

- Überschriften aus Schriftgrößen ableiten und einfache Tabellen aus Zeilen-
  und Spaltenlagen rekonstruieren.

### Etappe 8 — App-Bedienung

- Direkte Auswahl von Fastra als Ziel-App (Markdown lässt sich bereits in der
  zugeordneten Standard-App öffnen).
- Homebrew-Cask neben dem DMG.

### Nicht geplant

- Gegenrichtung Markdown nach DOCX/PDF/ODT: Pandoc könnte es, aber es verändert
  die Positionierung als Import-Werkzeug und verwischt die Fastra-Grenze. Erst
  nach den Etappen 1 bis 5 neu bewerten.
- XLSB (undokumentiertes Binärformat, selten) und MHTML (auf dem Mac selten).

### iWork-Formate (Pages und Numbers) — bewusste Grenze

Entscheidung vom 2026-07-29: kein iWork-Import. Weder Pandoc noch `textutil`
lesen iWork-Dateien. Ohne die installierten Apple-Apps bliebe nur das
Reverse-Engineering des undokumentierten IWA-Formats. Ein Importweg, der Pages
oder Numbers voraussetzt und per AppleScript nach DOCX beziehungsweise XLSX
exportiert, lohnt den Aufwand nicht. Wer eine Pages-/Numbers-Datei umwandeln
will, exportiert sie in der jeweiligen Apple-App als DOCX beziehungsweise XLSX
und nutzt den normalen Import. Keynote fällt unter dieselbe Grenze.

## Nächste technische Produktarbeit (2026-09-05)

- Nach Abbruch- und Speicherarbeit einstellbare Batch-Parallelität mit stabiler
  Ergebnisreihenfolge, Kollisionsschutz und gesonderter OCR-Begrenzung ergänzen;
  zunächst zwei gleichzeitige Dokumente messen.

## Fastra-Integration

Die Seite von Poor Man's Text ist erledigt: `poormans-text --formats [--json]`
veröffentlicht den Formatkatalog samt Endungen, Ablageform und
Werkzeugverfügbarkeit, sodass Fastra beim Öffnen entscheiden kann, ohne eigenes
Formatwissen zu pflegen. Fastra ruft die CLI mit einem eigenen Ziel auf, fragt
vorher sichtbar nach und lässt Quelle und erzeugtes Markdown getrennt.

Offen bleibt auf der Seite des Hosts:

- Warnungen und Formatverluste vor dem Öffnen zusammenfassen. Fastra bekommt sie
  bereits über `--json`; die Darstellung liegt beim Host.
- Eine direkte Library-Anbindung statt des CLI-Aufrufs wäre erst nötig, wenn
  Fortschrittsanzeige oder Abbruch während einer Umwandlung gefordert werden.
  Der Prozessweg bleibt bis dahin die einfachere und besser isolierte Grenze.

## Technische Referenzen

- [Apple Vision](https://developer.apple.com/documentation/vision) — lokale
  Text- und Dokumenterkennung in Bildern.
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit/pdfdocument) —
  Seiten, Textauswahl und PDF-Verarbeitung.
