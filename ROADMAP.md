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

## Offene Härtung aus der CodeQA-Kampagne (Stand 2026-09-10)

Zwei Punkte außerhalb des ZIP-Tors sind belegt, aber bewusst nicht umgesetzt,
weil sie eine Entwurfsentscheidung brauchen:

- **Spaltenerkennung gegen Tabellenzeilen.** `PDFTextLayout.ordered` liest zwei
  Gruppen links und rechts der Seitenmitte als zwei Spalten und gibt erst alle
  linken, dann alle rechten Zeilen aus. Für ein echtes Zweispaltenlayout ist das
  richtig; für Tabellen- oder Inhaltsverzeichniszeilen („Kapitel eins … 5") wäre
  es falsch, weil die Zuordnung Beschriftung↔Zahl verloren ginge. Auf
  Funktionsebene ist das reproduziert; über ein echtes PDF konnte es bisher
  niemand auslösen, weil `PDFTextLayout.lines` solche Zeilen nicht auftrennt.
  Beide Fälle sind geometrisch nicht sicher zu unterscheiden — nötig wäre ein
  zusätzliches Merkmal (Zeilendichte je Spalte, Punktführung, Spaltenbreite),
  nicht eine weitere Schwelle.
- **Geprüfter Deskriptor für Bilder.** `ImageAdapter.imageProbe` beschreibt den
  Pfad mit `resourceValues` und öffnet ihn danach ein zweites Mal über
  `CGImageSourceCreateWithURL`. Für PDF wurde genau dieses Muster bereits durch
  einen gemeinsamen Deskriptor ersetzt. Bei Bildern hieße das, die Datei
  vollständig in den Speicher zu lesen (`CGImageSourceCreateWithData`), was
  `kCGImageSourceShouldCache: false` bewusst vermeidet. Die zentrale
  `S_IFREG`-Prüfung in `DocumentConverter.detectInput` weist eine untergeschobene
  FIFO heute schon ab; offen bleibt nur das schmale Fenster dazwischen.

## Offene Punkte der App (Stand 2026-09-10)

Belegt, aber bewusst nicht in der Kampagne umgesetzt:

- **Nicht reproduziert, deshalb nur notiert:** Die Anhangnamen eines
  Flat-RTFD werden beim Auspacken ungeprüft als Pfadbestandteile benutzt. Ein
  Ausbruch über `../` ließ sich nicht konstruieren — AppKit scheint den Namen
  beim Schreiben zu bereinigen —, belegt ist er damit aber auch nicht. Die
  übrigen Wege des Projekts vergeben für fremde Anhänge bewusst eigene Namen.

## Offene Punkte der CLI (Stand 2026-09-10)

Belegt, aber bewusst nicht in der Kampagne umgesetzt:


## Offene Punkte der Tabellenleser (Stand 2026-09-10)

Belegt, aber bewusst nicht in der Kampagne umgesetzt:

- **Zwei Zeilenbudgets für dasselbe Modell.** CSV/TSV erlauben 1 000 000 Zeilen
  und 5 000 000 Zellen, die drei Arbeitsmappen-Leser 100 000 und 1 000 000 —
  beide Wege enden im selben Renderer. Eine Tabelle mit 150 000 Zeilen wird
  also als CSV angenommen und als ODS abgelehnt. Welche Zahl gelten soll, ist
  eine Produktentscheidung.
- **Trennzeichen auf Graphem-Ebene.** Der CSV-Parser vergleicht `Character`
  statt Unicode-Skalare. Ein Komma mit folgendem Kombinationszeichen ist ein
  anderes Graphem und trennt deshalb nicht — dieselbe Klasse, die im
  Frontmatter-Escaping schon behoben ist. Der Umbau berührt die gesamte
  Zustandsmaschine des Parsers.

## Offene Härtung des ZIP-Tors (Stand 2026-09-10)

Die CodeQA-Kampagne vom 2026-09-10 hat drei Punkte belegt, aber bewusst nicht
umgesetzt, weil sie eine Abwägung gegen reale, nicht ganz regelkonforme Archive
verlangen. Alle drei entstehen daraus, dass ein anderer Entpacker dieselbe Datei
anders lesen kann als `ZIPArchiveInspector`:

- **Ungeprüfte Bereiche der Datei.** Geprüft wird nur, dass das
  Zentralverzeichnis vor dem Schlussblock endet, nicht dass es unmittelbar davor
  endet. In eine Lücke passt ein zweites, vollständiges Verzeichnis. Ebenso darf
  vor dem Verzeichnis beliebiges unreferenziertes Material liegen, und hinter dem
  Deflate-Strom eines Eintrags beliebiger Füllstoff (`Z_STREAM_END` wird
  verlangt, `avail_in == 0` nicht). Keines der 600 daraufhin geprüften echten
  Archive hat eine solche Lücke — nach APPNOTE dürfen dort aber Signatur- und
  Entschlüsselungsblöcke stehen, deshalb ist ein hartes `==` nicht ohne Prüfung
  gegen ein größeres Feld einzuführen.
- **Auswahl des Schlussblocks.** `endOfCentralDirectory` verlangt, dass
  Kommentarlänge und Dateiende zusammenpassen, und sucht sonst weiter nach vorn.
  Info-ZIP `unzip` und Pythons `zipfile` nehmen dagegen schlicht das letzte
  Vorkommen der Signatur. Bei zwei Schlussblöcken arbeiten beide Seiten mit
  verschiedenen Eintragssätzen. Die strengere Regel ist richtig; offen ist, ob
  eine Abweichung zum Abbruch führen soll.
- **Speicher bei der Erkennung.** Jeder `packageContents`/`inspectionSnapshot`
  liest die vollständige Fremddatei in den Heap — bis zu 1 GiB Spitze, auch wenn
  nur der vier Byte lange `mimetype`-Eintrag gebraucht wird. Ein streamender
  Zugriff über den Deskriptor auf Schlussblock, Verzeichnis und Zieleintrag
  würde reichen.

## Technische Referenzen

- [Apple Vision](https://developer.apple.com/documentation/vision) — lokale
  Text- und Dokumenterkennung in Bildern.
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit/pdfdocument) —
  Seiten, Textauswahl und PDF-Verarbeitung.
