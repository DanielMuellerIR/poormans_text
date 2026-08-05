# Poor Man's Text — Roadmap

Hier steht nur offene Produktarbeit und bewusst gesetzte Formatgrenzen.
Erledigte Punkte werden beim Release aus dieser Datei entfernt und in
[CHANGELOG.md](CHANGELOG.md) festgehalten.

Die formatneutrale Engine, sichere Inhaltserkennung und wählbare dauerhafte oder
temporäre Veröffentlichung sind vorhanden. RTF, RTFD, DOCX/DOCM/DOTX/DOTM,
ODT, DOC, ODS, XLSX, XLS und ODM sind implementiert. Ihre Importwege stehen in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Formatplan

| Format | Geplanter Importweg | Aufwand | Erwartbare Qualität | Priorität |
|---|---|---:|---|---:|
| Bilder | Original als Asset plus lokales Vision-OCR in Leserichtung | mittel | Text gut bei sauberen Scans, Layout nur angenähert | 4 |
| PDF | PDFKit-Text zuerst, seitenweises Vision-OCR als Fallback | groß | Inhalt brauchbar, Layout/Spalten/Tabellen deutlich verlustbehaftet | 5 |

Vision und PDFKit sind macOS-Systemframeworks und benötigen keinen zusätzlichen
OCR-Dienst. PDF ist kein Pandoc-Eingabeformat.

### iWork-Formate (Pages und Numbers) — bewusste Grenze

Entscheidung vom 2026-07-29: kein iWork-Import. Weder Pandoc noch `textutil`
lesen iWork-Dateien. Ohne die installierten Apple-Apps bliebe nur das
Reverse-Engineering des undokumentierten IWA-Formats. Ein Importweg, der Pages
oder Numbers voraussetzt und per AppleScript nach DOCX beziehungsweise XLSX
exportiert, lohnt den Aufwand nicht. Wer eine Pages-/Numbers-Datei umwandeln
will, exportiert sie in der jeweiligen Apple-App als DOCX beziehungsweise XLSX
und nutzt den normalen Import.

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
  ablehnen; Seiten- und Pixelbudgets einführen.

PDF bleibt ausdrücklich eine Inhaltsübernahme, keine Layoutreproduktion.
Mehrspalten, Tabellen, Kopf-/Fußzeilen und Lesereihenfolge brauchen reale
Regressionstests und können trotz OCR manuelle Korrektur erfordern.

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

## Externe Verifikation

- Der echte Sparkle-Update-Weg, bei dem eine ältere installierte Fassung ersetzt
  wird, ist erst mit dem nächsten Release prüfbar. Version 0.7.0 ist der Einstieg
  und musste einmal von Hand installiert werden.
- Die vom Nutzer korrigierte Markdown-Datei für die noch ausstehende
  RTFD-Ausgabeanalyse liegt noch nicht vor.

## Technische Referenzen

- [Apple Vision](https://developer.apple.com/documentation/vision) — lokale
  Text- und Dokumenterkennung in Bildern.
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit/pdfdocument) —
  Seiten, Textauswahl und PDF-Verarbeitung.
