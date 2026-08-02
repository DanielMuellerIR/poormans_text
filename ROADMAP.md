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

DOCX, ODT und DOC sind seit 0.6.0 implementiert und stehen nicht mehr in dieser
Tabelle; ihr tatsächlicher Importweg steht in [CHANGELOG.md](CHANGELOG.md) und
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

| Format | Geplanter Importweg | Aufwand | Erwartbare Qualität | Priorität |
|---|---|---:|---|---:|
| ODS | Nativer Paketleser in ein gemeinsames Workbook-Modell | mittel | Werte und mehrere Blätter gut; Layout, Diagramme und Merges verlustbehaftet | 3 |
| XLSX | Nach ODS in dasselbe Workbook-Modell; Pandoc als unabhängiger Vergleich | mittel | Werte und mehrere Blätter gut | 3 |
| XLS | Eigener OLE-Adapter nach XLSX | groß | abhängig von Formeln, Altobjekten und Makros | 3 |
| Bilder | Original als Asset plus lokales Vision-OCR in Leserichtung | mittel | Text gut bei sauberen Scans, Layout nur angenähert | 4 |
| PDF | PDFKit-Text zuerst, seitenweises Vision-OCR als Fallback | groß | Inhalt brauchbar, Layout/Spalten/Tabellen deutlich verlustbehaftet | 5 |
| ODM | OpenDocument-Master samt verlinkten Teildokumenten sicher auflösen | groß | nur mit vollständigem lokalem Dokumentverbund zuverlässig | 6 |

Falls mit „ODM“ eigentlich „ODT“ gemeint war, ist es bereits in Priorität 2
abgedeckt. Echtes `.odm` bleibt separat: Ein Masterdokument kann lokale oder
fehlende/externe Teildokumente referenzieren und darf diese nicht still laden.

### iWork-Formate (Pages und Numbers) — bewusste Grenze

Entscheidung vom 2026-07-29: kein iWork-Import. Weder Pandoc noch `textutil`
lesen iWork-Dateien. Ohne die installierten Apple-Apps bliebe nur das
Reverse-Engineering des undokumentierten IWA-Formats (Snappy-komprimierte
Protobuf-Archive, seit den 2013er-Versionen); ein Importweg, der die jeweiligen
iWork-Apps voraussetzt (AppleScript-Export nach DOCX/XLSX), lohnt den Aufwand
nicht. Die alten XML-Varianten (bis ’09) wären nur bei trivialer Umsetzung
interessant gewesen — sie öffnen aber nicht einmal die heutigen Apple-Apps
mehr. Wer eine Pages-/Numbers-Datei umwandeln will, exportiert sie in
Pages/Numbers selbst als DOCX beziehungsweise XLSX und nutzt den normalen
Import.

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

Ergänzung aus dem Release-Review 2026-07-27 (beide betreffen den veröffentlichten
JSON-Vertrag, nicht das Verhalten — Fastra kommt mit beiden zurecht):

- `--formats --json` lässt `unavailableReason` bei verfügbaren Formaten ganz weg,
  weil Swift nil-Optionals nicht kodiert. Ein Konsument muss deshalb „Schlüssel
  fehlt" und „Schlüssel ist null" gleich behandeln. Explizites `null` wäre der
  klarere Vertrag.
- Im Konvertierungs-JSON bleibt `input` der übergebene Pfad (`/tmp/…`), während
  `markdownFile` und `assets` symlink-aufgelöst zurückkommen (`/private/tmp/…`).
  Ein Host, der die Pfade gegeneinander vergleicht, stolpert darüber. Entweder
  beide Seiten auflösen oder beide roh lassen.

Ergänzung aus dem Code-Review 2026-08-02:

- `Sources/PoorMansTextCore/ZIPArchiveInspector.swift` (mittel): Für DOCX genügen
  die beiden Eintragsnamen `[Content_Types].xml` und `word/document.xml`. Weder
  der Hauptinhaltstyp aus `[Content_Types].xml` noch die Wurzel von
  `word/document.xml` werden geprüft; damit gelten auch DOCM- und DOTX-Pakete
  als `.docx`. Makros verschwinden dann ohne eigene Verlustwarnung, und ein
  späterer Pandoc-Fehler sieht wie ein Konverterfehler statt wie eine ungültige
  Eingabe aus. Vor der Umsetzung ist zu entscheiden, ob solche Pakete abgelehnt
  werden oder mit einer eigenen Warnung weiterlaufen: Ein reines Ablehnen nähme
  Nutzern eine heute funktionierende Umwandlung.

## Befunde aus dem Abgleich mit md_clip (2026-07-29)

Quelle: Vergleich der Rich-Text-nach-Markdown-Strecke beider Projekte auf
denselben Eingaben. Beide benutzen `pandoc --to=gfm-raw_html` und räumen danach
nach. Hier stehen nur die Stellen, an denen md_clip nachweisbar besser liegt.
Umgekehrt hat md_clip am 2026-07-29 den Nachbereitungs-Stil von Poor Man's Text
übernommen: Hard-Break als zwei Leerzeichen statt sichtbarem Backslash, `\-` und
`\_\_\_` entescapen, ein Absatz aus nur einem fett gesetzten Bullet wird ein
Listenpunkt.

Stark:

- `Sources/PoorMansTextCore/RichTextConverter.swift:199-212` (stark): Der
  Pandoc-RTF-Reader verliert bei RTF von TextEdit, Pages und dem macOS-Clipboard
  die Absatzgrenzen. Diese Programme schreiben das Absatzende als Backslash
  gefolgt von einem echten Zeilenumbruch — im Schwesterprojekt md_clip liegt
  ein solches RTF als `tests/fixtures/word-rtf.rtf`. Pandoc liest diese
  Kurzform als Zeilenumbruch innerhalb eines Absatzes; aus zwei Absätzen wird
  einer. md_clip korrigiert das vor pandoc in `rtf_fix_escaped_newlines`
  (`\` + Newline → `\par` + Newline, escapte Backslashes bleiben unberührt) —
  der byte-genaue Vorlauf `preservingEmptyRTFParagraphs` wäre hier die passende
  Stelle. Alternative: `.rtf` genau wie `.rtfd` über `textutil` einlesen, das
  die Kurzform von sich aus richtig umsetzt. Dagegen spricht nur die
  Medienextraktion, die pandoc mit `--extract-media` mitbringt.
  Nachstellen: `poormans-text` auf dieses Fixture laufen lassen — erwartet sind
  zwei Absätze, geliefert wird einer.
- `Sources/PoorMansTextCore/RichTextConverter.swift:112-127` (stark): Derselbe
  RTF-Reader verpackt Listeneinträge in `<li><p>…</p></li>`, woraus pandoc eine
  lose Liste mit Leerzeile zwischen den Einträgen schreibt. md_clip entfernt
  diese Absatzhülle vor pandoc in `unwrap_list_paragraphs`; hier wäre die
  Stelle, an der das erzeugte HTML schon einmal angefasst wird (der
  Leerabsatz-Marker), bevor es an `HTMLDocumentConverter` geht. Derselbe
  RTF-Fixture-Lauf zeigt es.

Optional/niedrig:

- `Sources/PoorMansTextCore/MarkdownNormalizer.swift:40-59` (optional): Ein
  Hard-Break, der nur Layout war, wird unverändert zu zwei Leerzeichen. Bei
  Text aus `<br>`-Ketten steht danach an jeder Zeile unnötiger Trailing-Space,
  auch an Listeneinträgen, und eine Zeile aus zwei Leerzeichen ersetzt die
  Leerzeile zwischen zwei Absätzen. md_clip löscht den Umbruch stattdessen
  ganz, wenn die nächste Zeile leer ist, mit einem Listenpunkt beginnt oder das
  Dokument endet. Für Dokumentimport ist das weniger dringend als für
  Clipboard-Text, weil DOCX und ODT echte Absätze mitbringen.
- `Sources/PoorMansTextCore/HTMLDocumentConverter.swift:53` (optional):
  `--wrap=preserve` ist für Dokumente richtig, weil die Zwischenstufe
  `--to=html5` ebenfalls mit `--wrap=preserve` erzeugt wird und damit keine
  fremden Umbrüche einbringt. Sollte diese Strecke je HTML aus einer anderen
  Quelle bekommen (Browser, Clipboard, fremde Konverter), wäre `--wrap=none`
  nötig: dort ist der Zeilenumbruch im Quell-HTML reine Formatierung und
  `preserve` schleppt ihn in das Markdown.

## Technische Referenzen

- [Pandoc User's Guide](https://pandoc.org/MANUAL.html) — Eingabeformate,
  Medienextraktion und DOCX-Änderungsbehandlung.
- [Apple Vision](https://developer.apple.com/documentation/vision) — lokale
  Text- und Dokumenterkennung in Bildern.
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit/pdfdocument) —
  Seiten, Textauswahl und PDF-Verarbeitung.
- [OpenDocument 1.3 Packages](https://docs.oasis-open.org/office/OpenDocument/v1.3/OpenDocument-v1.3-part2-packages.html)
  — Pakete, Manifest und Teildokumente.
