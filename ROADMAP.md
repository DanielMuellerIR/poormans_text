# Poor Man's Text — Roadmap

Hier steht nur offene Produktarbeit und bewusst gesetzte Formatgrenzen.
Erledigte Punkte werden beim Release aus dieser Datei entfernt und in
[CHANGELOG.md](CHANGELOG.md) festgehalten.

Die formatneutrale Engine, sichere Inhaltserkennung und wählbare dauerhafte oder
temporäre Veröffentlichung sind vorhanden. RTF, RTFD, DOCX/DOCM/DOTX/DOTM,
ODT, DOC, ODS, XLSX, XLS, ODM, PDF sowie PNG, JPEG, HEIC und TIFF sind
implementiert. Ihre Importwege stehen in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Etappenplan (Stand 2026-09-02)

Die Etappen sind nach Nutzen je Aufwand sortiert und bauen aufeinander auf.
Jede Etappe ist für sich releasefähig. Ein neuer Adapter meldet sich weiterhin
nur über `supportedFormatDescriptors`; der Orchestrator bleibt unverändert.
Was [docs/MARKITDOWN-COMPARISON.md](docs/MARKITDOWN-COMPARISON.md) vorschlägt,
ist hier eingeordnet. Etappe 1 (mehrere Eingaben und Ordner in CLI und App) ist
umgesetzt und steht bis zum nächsten Release im Changelog unter „Unreleased“.

### Etappe 2 — Systemintegration ohne Terminal

- Finder-Schnellaktion „In Markdown umwandeln“ als Dienst der App
  (`NSServices` in `App/Info.plist`, Handler in `PoorMansTextAppSupport`).
- Dienst für markierten Rich Text in beliebigen Apps: RTF/RTFD von der
  Zwischenablage durch den Rich-Text-Adapter, Markdown zurück auf die
  Zwischenablage. Nutzt den vorhandenen temporären Veröffentlichungsweg.
- Kurzbefehle-Aktion „Dokument in Markdown umwandeln“ über App Intents
  (macOS 13+), mit denselben Optionen wie die CLI.

### Etappe 3 — CLI-Ausgabewege

- `--stdout`: Markdown auf die Standardausgabe, Diagnosen auf stderr. Enthaltene
  Bilder werden nicht materialisiert und als Warnung gemeldet.
- `--frontmatter`: YAML-Kopf mit Titel, Autor und Datum aus `docProps/core.xml`
  (OOXML), `meta.xml` (OpenDocument) und dem RTF-Info-Block. Der Kern liefert
  dafür `ConversionResult.metadata`; ohne Schalter bleibt die Ausgabe unverändert.
- `--textbundle`: Ergebnis als `.textbundle` (Markdown plus `assets/` und
  `info.json`), damit Bear, iA Writer und Ulysses es direkt öffnen.

### Etappe 4 — Kleine Formatgewinne mit vorhandenen Bausteinen

- XLSM, XLTX und XLTM über das DOCM/DOTX-Muster im Tabellen-Adapter; Makros und
  Vorlagenverhalten als erwarteter Verlust.
- CSV und TSV als Ein-Blatt-Arbeitsmappe. Trennzeichen aus den ersten Zeilen
  bestimmen, Encoding aus BOM oder als UTF-8 mit Latin-1-Rückfall.
- GIF, BMP und WebP im Bildadapter; ImageIO liest sie bereits.
- HTML/XHTML und `.webarchive` über den vorhandenen HTML-Rewriter. Lokale
  Bilder werden Assets, entfernte Verweise bleiben Links und werden als Verlust
  gemeldet; nichts wird geladen.
- Pandoc-Leser für Einzeldateien: LaTeX, DocBook, Org, MediaWiki, Textile, FB2.
  EPUB zusätzlich durch das Paket-Gate.

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
- MSG (Outlook) über den OLE-Leser des XLS-Parsers.

### Etappe 7 — Qualität des PDF-Imports

- Überschriften aus Schriftgrößen ableiten; Silbentrennung am Zeilenende
  zusammenführen; zweispaltige Seiten anhand der Textpositionen erkennen;
  einfache Tabellen aus Zeilen- und Spaltenlagen rekonstruieren.
- OCR-Sprachen wählbar (`--ocr-language de,en`, App-Einstellung); Vision läuft
  heute ohne Sprachliste.

### Etappe 8 — App-Bedienung

- Markdown-Vorschau im Fenster, Warnungen als Liste, Knopf „in Fastra öffnen“.
- Zielordner wählbar; Tabellenformat, OCR und Frontmatter als gemerkte
  Einstellungen; Fortschritt und Abbruch für lange Umwandlungen über das
  vorhandene `ConversionProgress`.
- Deutsche Lokalisierung der Oberfläche.
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
- Eine direkte Library-Anbindung statt des CLI-Aufrufs wäre erst nötig, wenn
  Fortschrittsanzeige oder Abbruch während einer Umwandlung gefordert werden.
  Der Prozessweg bleibt bis dahin die einfachere und besser isolierte Grenze.

## Technische Referenzen

- [Apple Vision](https://developer.apple.com/documentation/vision) — lokale
  Text- und Dokumenterkennung in Bildern.
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit/pdfdocument) —
  Seiten, Textauswahl und PDF-Verarbeitung.
