# Poor Man's Text — Roadmap

Hier steht nur offene Produktarbeit. Erledigte Punkte werden beim Release aus
dieser Datei entfernt und in [CHANGELOG.md](CHANGELOG.md) festgehalten.

## Zielarchitektur vor weiteren Formaten

Der vorhandene `PoorMansTextCore` ist bereits unabhängig von SwiftUI und wird von
App und CLI gemeinsam benutzt. Vor dem zweiten Konverter wird daraus eine kleine
formatneutrale API gemäß [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md):

- Eingabeformat sicher erkennen statt nur die Dateiendung zu glauben.
- Einheitliche Anfrage, Optionen, Fortschritt, Warnungen und Ergebnisstruktur.
- Formatadapter registrieren, ohne GUI-Rückfragen in den Kern einzubauen.
- Plattformnahe Leser für AppKit, Vision und PDFKit von der formatneutralen
  Orchestrierung trennen.
- Ausgabeziel wählbar machen: dauerhafter Nachbarordner für Poor Man's Text,
  temporärer Import für eine spätere Fastra-Integration.

Erfolgskriterium: Fastra kann das Library-Produkt später einbinden, vor einer
Konvertierung selbst fragen und danach die erzeugte Markdown-Datei öffnen, ohne
Code aus der Poor-Man's-Text-GUI zu übernehmen.

## Formatplan

Stand der lokalen Werkzeuge am 2026-07-21: Pandoc 3.9 liest `rtf`, `docx` und
`odt`; macOS `textutil` liest zusätzlich das alte Binärformat `doc`; PDF ist
kein Pandoc-Eingabeformat. Vision und PDFKit sind Systemframeworks und benötigen
keinen zusätzlichen OCR-Dienst.

| Format | Geplanter Importweg | Aufwand | Erwartbare Qualität | Priorität |
|---|---|---:|---|---:|
| RTF | Pandoc direkt mit Medienextraktion; Cocoa-HTML als Vergleich/Fallback | klein | ähnlich RTFD, eingebettete Bilder separat prüfen | 1 |
| DOCX | Pandoc direkt mit `--extract-media`; Änderungsmodus explizit festlegen | mittel | gute Struktur, Bilder, Listen und Tabellen | 2 |
| ODT | Pandoc direkt mit Medienextraktion | klein–mittel | meist ähnlich DOCX | 2 |
| DOC | `textutil` nach HTML, danach vorhandene HTML-/Pandoc-Pipeline | mittel | abhängig vom macOS-Importer; alte Sonderobjekte verlustreich | 3 |
| Bilder | Original als Asset plus lokales Vision-OCR in Leserichtung | mittel | Text gut bei sauberen Scans, Layout nur angenähert | 4 |
| PDF | PDFKit-Text zuerst, seitenweises Vision-OCR als Fallback | groß | Inhalt brauchbar, Layout/Spalten/Tabellen deutlich verlustbehaftet | 5 |
| ODM | OpenDocument-Master samt verlinkten Teildokumenten sicher auflösen | groß | nur mit vollständigem lokalem Dokumentverbund zuverlässig | 6 |

Falls mit „ODM“ eigentlich „ODT“ gemeint war, ist es bereits in Priorität 2
abgedeckt. Echtes `.odm` bleibt separat: Ein Masterdokument kann lokale oder
fehlende/externe Teildokumente referenzieren und darf diese nicht still laden.

## Etappe 1 — RTF und formatneutrale Engine

- `InputFormat`, `ConversionRequest` und `DocumentConverter` einführen.
- Bestehenden RTFD-Konverter als ersten Adapter weiterführen.
- RTF-Adapter mit echten Fixtures für Fett/Kursiv, Farben, Leerzeilen, Listen,
  Links und mindestens ein eingebettetes Bild bauen.
- Pandoc-Direktweg und `textutil`-HTML anhand derselben Fixtures vergleichen;
  Expected Output nie still regenerieren.
- CLI und App auf `.rtf` erweitern, ohne Formatlogik in deren Targets zu legen.

Freigabekriterium: kein Text- oder Bildverlust in den Fixtures, dieselben
atomaren Kollisionsregeln wie bei RTFD und unveränderte JSON-Exit-Semantik.

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

## Etappe 4 — Bilder und OCR

- Zunächst PNG, JPEG, HEIC und TIFF über ImageIO/NSImage akzeptieren.
- Originalbild immer unverändert in `images/` übernehmen und im Markdown
  verlinken; OCR-Text zusätzlich ausgeben, nicht anstelle des Bildes.
- Vision auf genaue Erkennung, automatische Sprache und Bounding-Box-Sortierung
  konfigurieren; Drehung und mehrseitiges TIFF berücksichtigen.
- Unsichere Erkennung kenntlich machen statt Text zu erfinden.

Vor Implementierung ist eine Produktentscheidung nötig: Standardmäßig nur Bild,
Bild plus OCR oder eine CLI-Option für beide Varianten.

## Etappe 5 — PDF

- Pro Seite zuerst eingebetteten Text mit PDFKit extrahieren.
- Seiten ohne ausreichenden Text lokal rendern und mit Vision OCR lesen.
- Seitenreihenfolge und Seitenmarken erhalten; Bilder nur dann separat
  extrahieren, wenn Position und Zuordnung zuverlässig bestimmbar sind.
- Passwortgeschützte, beschädigte und extrem große PDFs früh und verständlich
  ablehnen; Seiten-/Pixelbudgets einführen.

PDF bleibt ausdrücklich eine Inhaltsübernahme, keine Layoutreproduktion.
Mehrspalten, Tabellen, Kopf-/Fußzeilen und Lesereihenfolge brauchen reale
Regressionstests und können trotz OCR manuelle Korrektur erfordern.

## Später — Fastra-Integration

- Fastra erkennt ein importierbares Nicht-Markdown-Dokument und fragt vor jeder
  Konvertierung sichtbar nach.
- Erst nach Zustimmung ruft Fastra die Library mit einem temporären Ziel auf.
- Original und erzeugtes Markdown bleiben getrennt; Fastra schreibt nie zurück
  in das Quelldokument.
- Warnungen und Formatverluste werden vor dem Öffnen zusammengefasst.
- Eine dauerhafte Exportkopie entsteht nur auf einen zweiten ausdrücklichen
  Nutzerbefehl.

## Technische Referenzen

- [Pandoc User's Guide](https://pandoc.org/MANUAL.html) — Eingabeformate,
  Medienextraktion und DOCX-Änderungsbehandlung.
- [Apple Vision](https://developer.apple.com/documentation/vision) — lokale
  Text- und Dokumenterkennung in Bildern.
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit/pdfdocument) —
  Seiten, Textauswahl und PDF-Verarbeitung.
- [OpenDocument 1.3 Packages](https://docs.oasis-open.org/office/OpenDocument/v1.3/OpenDocument-v1.3-part2-packages.html)
  — Pakete, Manifest und Teildokumente.
