# Poor Man's Text — Roadmap

Hier steht nur offene Produktarbeit und bewusst gesetzte Formatgrenzen.
Erledigte Punkte werden beim Release aus dieser Datei entfernt und in
[CHANGELOG.md](CHANGELOG.md) festgehalten.

Die formatneutrale Engine, sichere Inhaltserkennung und wählbare dauerhafte oder
temporäre Veröffentlichung sind vorhanden. RTF, RTFD, DOCX/DOCM/DOTX/DOTM,
ODT, DOC, ODS, XLSX/XLSM/XLTX/XLTM, XLS, CSV/TSV, ODM, PDF, PPTX/PPTM/POTX,
ODP, IPYNB, HTML, Webarchive,
EPUB, LaTeX, DocBook, Org, MediaWiki, Textile, reStructuredText, FictionBook
sowie PNG, JPEG, HEIC, TIFF, GIF, BMP und WebP sind implementiert. Ihre Importwege stehen in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Etappenplan (Stand 2026-09-05)

Die Etappen sind nach Nutzen je Aufwand sortiert und bauen aufeinander auf.
Jede Etappe ist für sich releasefähig. Ein neuer Adapter meldet sich weiterhin
nur über `supportedFormatDescriptors`; der Orchestrator bleibt unverändert.
Was [docs/MARKITDOWN-COMPARISON.md](docs/MARKITDOWN-COMPARISON.md) vorschlägt,
ist hier eingeordnet. Die Etappen 1 (mehrere Eingaben und Ordner), 2 (Dienste,
bis auf App Intents), 3 (`--stdout`, `--frontmatter`, `--textbundle`) sowie 4
(kleine Formatgewinne) und 5 (Präsentationen und Notebooks) sind umgesetzt und stehen im Changelog zu Version 0.10.0.

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

## Fastra-Integration

Die Seite von Poor Man's Text ist erledigt: `poormans-text --formats [--json]`
veröffentlicht den Formatkatalog samt Endungen, Ablageform und
Werkzeugverfügbarkeit, sodass Fastra beim Öffnen entscheiden kann, ohne eigenes
Formatwissen zu pflegen. Fastra ruft die CLI mit einem eigenen Ziel auf, fragt
vorher sichtbar nach und lässt Quelle und erzeugtes Markdown getrennt.

Offen bleibt auf der Seite des Hosts:

- Warnungen und Formatverluste vor dem Öffnen zusammenfassen. Fastra bekommt sie
  bereits über `--json`; die Darstellung liegt beim Host.
- Eine direkte Library-Anbindung prüfen, falls Fastra typisierte
  Fortschrittscallbacks statt CLI-Ausgabe benötigt. Die CLI bietet bereits
  `--progress` und Abbruch über SIGINT/SIGTERM; deren Nutzung entscheidet der Host.

## Technische Referenzen

- [Apple Vision](https://developer.apple.com/documentation/vision) — lokale
  Text- und Dokumenterkennung in Bildern.
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit/pdfdocument) —
  Seiten, Textauswahl und PDF-Verarbeitung.
