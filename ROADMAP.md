# Poor Man's Text — Roadmap

Hier steht nur offene Produktarbeit. Erledigte Punkte werden beim Release aus
dieser Datei entfernt und in [CHANGELOG.md](CHANGELOG.md) festgehalten.

Die formatneutrale Engine, sichere Inhaltserkennung und wählbare dauerhafte oder
temporäre Veröffentlichung sind vorhanden. Die offenen Formate bauen auf der in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) beschriebenen Adaptergrenze auf.

## Formatplan

Stand der lokalen Werkzeuge am 2026-07-25: Pandoc 3.9.0.2 liest `rtf`, `docx`,
`odt` und `xlsx`, aber weder `ods` noch `xls`; macOS `textutil` liest zusätzlich
das alte Binärformat `doc`. PDF ist kein Pandoc-Eingabeformat. Vision und PDFKit
sind Systemframeworks und benötigen keinen zusätzlichen OCR-Dienst.

| Format | Geplanter Importweg | Aufwand | Erwartbare Qualität | Priorität |
|---|---|---:|---|---:|
| DOCX | Pandoc direkt mit `--extract-media`; Änderungsmodus explizit festlegen | mittel | gute Struktur, Bilder, Listen und Tabellen | 1 |
| ODT | Pandoc direkt mit Medienextraktion | klein–mittel | meist ähnlich DOCX | 1 |
| DOC | `textutil` nach HTML, danach vorhandene HTML-/Pandoc-Pipeline | mittel | abhängig vom macOS-Importer; alte Sonderobjekte verlustreich | 2 |
| ODS | Nativer Paketleser in ein gemeinsames Workbook-Modell | mittel | Werte und mehrere Blätter gut; Layout, Diagramme und Merges verlustbehaftet | 3 |
| XLSX | Nach ODS in dasselbe Workbook-Modell; Pandoc als unabhängiger Vergleich | mittel | Werte und mehrere Blätter gut | 3 |
| XLS | Eigener OLE-Adapter nach XLSX | groß | abhängig von Formeln, Altobjekten und Makros | 3 |
| Bilder | Original als Asset plus lokales Vision-OCR in Leserichtung | mittel | Text gut bei sauberen Scans, Layout nur angenähert | 4 |
| PDF | PDFKit-Text zuerst, seitenweises Vision-OCR als Fallback | groß | Inhalt brauchbar, Layout/Spalten/Tabellen deutlich verlustbehaftet | 5 |
| ODM | OpenDocument-Master samt verlinkten Teildokumenten sicher auflösen | groß | nur mit vollständigem lokalem Dokumentverbund zuverlässig | 6 |

Falls mit „ODM“ eigentlich „ODT“ gemeint war, ist es bereits in Priorität 2
abgedeckt. Echtes `.odm` bleibt separat: Ein Masterdokument kann lokale oder
fehlende/externe Teildokumente referenzieren und darf diese nicht still laden.

## Etappe 2 — DOCX und ODT

- Gemeinsamen Pandoc-Containeradapter mit isoliertem Medienverzeichnis bauen.
- Pfade aus dem Container normalisieren und Traversal/entfernte Ressourcen
  weiterhin ablehnen.
- Überschriften, Fußnoten, Tabellen, Listen, Links, Bilder und Kommentare testen.
- Für DOCX bewusst entscheiden und dokumentieren, ob Änderungen angenommen,
  verworfen oder als Markup erhalten werden.

Freigabekriterium: reale, selbst erzeugte Dateien aus mindestens zwei Editoren
pro Format; Output-Diff gegen Pandoc direkt und gegen die jeweilige Quellansicht.

## Etappe 3 — Legacy-DOC

- `textutil`-Import als separaten Adapter kapseln, nicht als DOCX-Fallback tarnen.
- Klare Warnungen für nicht darstellbare OLE-Objekte, Textfelder und Makroinhalt.
- Binär-DOC-Fixtures mit Bildern, Tabellen und Umlauten versionieren.

Freigabekriterium: ehrlicher Fehler statt leerer oder teilweise verschwundener
Ausgabe; Quelle bleibt auch bei einem fehlerhaften Systemimport unverändert.

## Etappe 4 — Tabellendokumente

- Zuerst ODS in ein formatneutrales Workbook-Modell lesen.
- Pro Import zwischen GFM-Tabelle und reversibel escaptem tab-getrenntem Text
  wählen können.
- Mehrere Blätter in Quellreihenfolge als getrennte Markdown-Abschnitte ausgeben.
- Wiederholungen, leere Zellen, interne Umbrüche, Pipes, Formeln, Merges und
  Größenbudgets mit echten Mehrblatt-Fixtures testen.
- Danach XLSX und zuletzt XLS an dasselbe Modell anbinden.

Die geprüfte Darstellung und die bewussten Grenzen stehen in
[docs/SPREADSHEET-IMPORT.md](docs/SPREADSHEET-IMPORT.md).

## Etappe 5 — Bilder und OCR

- Zunächst PNG, JPEG, HEIC und TIFF über ImageIO/NSImage akzeptieren.
- Originalbild immer unverändert in `images/` übernehmen und im Markdown
  verlinken; OCR-Text zusätzlich ausgeben, nicht anstelle des Bildes.
- Vision auf genaue Erkennung, automatische Sprache und Bounding-Box-Sortierung
  konfigurieren; Drehung und mehrseitiges TIFF berücksichtigen.
- Unsichere Erkennung kenntlich machen statt Text zu erfinden.

Vor Implementierung ist eine Produktentscheidung nötig: Standardmäßig nur Bild,
Bild plus OCR oder eine CLI-Option für beide Varianten.

## Etappe 6 — PDF

- Pro Seite zuerst eingebetteten Text mit PDFKit extrahieren.
- Seiten ohne ausreichenden Text lokal rendern und mit Vision OCR lesen.
- Seitenreihenfolge und Seitenmarken erhalten; Bilder nur dann separat
  extrahieren, wenn Position und Zuordnung zuverlässig bestimmbar sind.
- Passwortgeschützte, beschädigte und extrem große PDFs früh und verständlich
  ablehnen; Seiten-/Pixelbudgets einführen.

PDF bleibt ausdrücklich eine Inhaltsübernahme, keine Layoutreproduktion.
Mehrspalten, Tabellen, Kopf-/Fußzeilen und Lesereihenfolge brauchen reale
Regressionstests und können trotz OCR manuelle Korrektur erfordern.

## Fastra-Integration

Die Seite von Poor Man's Text ist erledigt: `poormans-text --formats [--json]`
veröffentlicht den Formatkatalog samt Endungen, Ablageform und
Werkzeugverfügbarkeit, sodass Fastra beim Öffnen entscheiden kann, ohne eigenes
Formatwissen zu pflegen. Fastra ruft die CLI mit einem eigenen Ziel auf, fragt
vorher sichtbar nach und lässt Quelle und erzeugtes Markdown getrennt.

Offen bleibt hier nur:

- Warnungen und Formatverluste vor dem Öffnen zusammenfassen — Fastra bekommt
  sie bereits über `--json`, die Darstellung liegt beim Host.
- Eine direkte Library-Anbindung statt des CLI-Aufrufs wäre erst nötig, wenn
  Fortschrittsanzeige oder Abbruch während einer Umwandlung gefordert werden.
  Der Prozessweg bleibt bis dahin die einfachere und besser isolierte Grenze.

## Code-Review-Nacharbeiten

Quelle: Code-Review-Triage 2026-07-24. Offene Härtungs- und Aufräumpunkte aus der
Review; unabhängig von den Formatetappen.

Stark:

- `scripts/install.sh:401-405` (stark): Nach einer bereits validierten
  Neuinstallation kann der Rollback ein zuvor als verdächtig eingestuftes Backup
  zurücktauschen. Rollback-on-suspicious-backup-Semantik prüfen; sicherer ist, das
  validierte neue Bundle zu behalten statt es zu verwerfen.
- `Sources/PoorMansTextAppSupport/CLIInstaller.swift:100-105` (stark): Latenter
  Pipe-Deadlock — stderr wird erst nach `waitUntilExit()` gelesen, sodass ein Kind
  mit mehr Ausgabe als der Pipe-Buffer blockiert. Korrekt ist nebenläufiges Lesen
  der Pipe während der Kindprozess läuft; das Read-Ende darf dafür nicht vorab
  geschlossen werden.
- `Sources/PoorMansTextCore/RichTextConverter.swift:278-325` (stark):
  `preservingEmptyRTFParagraphs` (bin-Skip, Lookahead) ist bislang nur durch
  Round-Trip-Tests abgedeckt. Gezielte Edge-Case-Tests ergänzen (z. B. escapte
  Backslashes, `\bin`-Blöcke, Marker an Puffergrenzen).

Optional/niedrig:

- `Sources/PoorMansTextCore/ConversionResult.swift:43-59` (optional): Legacy-Init
  ohne repo-internen Aufrufer. Externe Nutzung ausschließen, dann entfernen.
- `Sources/PoorMansTextAppSupport/WarningPresentation.swift` (optional): Trivialer
  `[String]`-Wrapper; einzige Nutzung `ContentView.swift:155` ist eine
  Identitätstransformation. Wrapper samt Test auflösen.
- `Sources/PoorMansTextCLI/main.swift:215-227` (optional): Manuelle nil-Defaults im
  Fehlerpfad. Defaults in `JSONResponse` selbst oder in einen kleinen Helper
  verlagern.

## Technische Referenzen

- [Pandoc User's Guide](https://pandoc.org/MANUAL.html) — Eingabeformate,
  Medienextraktion und DOCX-Änderungsbehandlung.
- [Apple Vision](https://developer.apple.com/documentation/vision) — lokale
  Text- und Dokumenterkennung in Bildern.
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit/pdfdocument) —
  Seiten, Textauswahl und PDF-Verarbeitung.
- [OpenDocument 1.3 Packages](https://docs.oasis-open.org/office/OpenDocument/v1.3/OpenDocument-v1.3-part2-packages.html)
  — Pakete, Manifest und Teildokumente.
