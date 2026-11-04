# P00: Referenz und Funktionsmatrix 2026-11-04

PMT-Quellstand: `17328f17d63843025b33b45a87fa3d13db5e11d7`.
Fastra-Quellstand: `55ca70579861954a21cfbd22d96e12059fec68db`.
Reale Mac-CLI 0.41.7, SHA-256 `39da1018a09a76a801cf7c35c1670ffba0d28458d72343cb9f699df1f3e0ba3e`.
Mac-Host macOS 26.7.2 arm64. Binary nicht neu gebaut: Hash und Version sind belegt,
Zuordnung dieses Binaries zum Quell-HEAD ist ohne Build-/Signaturmanifest offen.
Fastra auf Linux: Originalparser und originaler Service mit vorhandenem
runProcess-Testhaken; AppKit-/ObservableObject-/GitRunner-Typen ausschließlich
für Kompilation gestubbt. Keine echte App-/GUI-/GitRunner-Abnahme.

## Echte Mac-Ergebnisse

CSV (Unicode/Leerzeichen/Doppelpunkt im Dateinamen), XLSX (2×2 Zellen), IPYNB
(Markdown+Code+gespeicherte Ausgabe), RTF (CP1252 Grüße + Unicode α), bestehendes
DOCX mit PNG, MBOX mit zwei Nachrichten und ENEX mit zwei Notizen konvertieren.
7/7 Quellen bleiben SHA-256-identisch. Alle für sechs synthetische Eingaben
unabhängig festgelegten Inhaltsmarker sind im Markdown vorhanden.
DOCX wird gegen `Fixtures/WordProcessing/source.md` geprüft: Überschrift,
Grüße/Äpfel/Birnen, zwei Listeneinträge, zwei Tabellenzeilen, Fußnotentext und
Bildlink sind vorhanden. Bildbytes stimmen SHA-256-identisch mit fixture.png überein.
Alle sieben Berichte werden als JSON gelesen; ihre Quellhashes und Ausgabehashes/Bytezahlen stimmen unabhängig mit den erfassten Dateibytes überein. Vorhandene Mappingbereiche liegen innerhalb der UTF8-Ausgabebytes und teilen keine UTF8-Zeichen. Fehlende Mappings tragen explizite Nichtverfügbarkeitsdiagnosen. `verify-baseline.py` reproduziert diese Prüfungen.
Das ist ein kleiner Basiskorpus, keine Vollabnahme aller Formate/Optionen.

Reale Fehler: fehlende Quelle=66; fehlendes Pandoc=69; JSON+stdout=64;
bestehendes Ausgabeziel=73; Sammlung+stdout=64 und keine Markdown-Ausgabe.
SIGTERM beim großen CSV ergibt 130, `ok:false`/`Conversion cancelled.`, kein
veröffentlichtes Ausgabeziel. Nachkommen-Cleanup und Abbruchlatenz sind hier
nicht unabhängig nachgewiesen und bleiben P03/P13.

## Fähigkeitsmatrix P00

Alle Zeilen haben Status **Bestand erfasst, vollständige Mac-/Linux-Abnahme offen**,
außer den oben genannten sieben kleinen realen Mac-Proben. Linux-Paketangaben
sind offene Prüfkandidaten aus LINUX-PORT, keine verifizierte Paketverfügbarkeit.

| Format/Endungen | Core-Backend / deklarierte externe Werkzeuge | Referenz im Bestand | unabhängige Abnahme / Linux-Grenze | Paket |
|---|---|---|---|---|
| RTF | RichTextAdapter, Pandoc | FixtureFactory, RichTextConverterTests; reale CP1252-Probe | Unicode/Text/Bilder/Listen; Foundation-Encoding/ImageIO | P06/P10 |
| RTFD-Paket | RichTextAdapter, textutil+Pandoc | FixtureFactory, RTFD-*Tests | Bilder/Listen/Paketpfade; textutil ersetzen | P10 |
| DOCX/DOCM/DOTX/DOTM | WordProcessingPackageAdapter, Pandoc | Fixtures/WordProcessing, WordProcessingAdapterTests | Text/Bilder/Kommentare/Änderungen; reale DOCX-Probe | P06 |
| ODT | WordProcessingPackageAdapter, Pandoc | pandoc/libreoffice/textutil.odt, annotated.odt | Text/Bilder/Annotationen/Remote-Sperre | P06 |
| DOC | LegacyWordAdapter, textutil+Pandoc | libreoffice.doc, textutil.doc | Listen/Bilder/Encoding; Linux LibreOffice prüfen | P10 |
| ODS | SpreadsheetAdapter, intern ZIP/XML | Fixtures/Spreadsheets/multisheet.ods | Blatt-/Zellzählung, Werte, Merge-/Formelwarnungen | P07 |
| XLSX/XLSM/XLTX/XLTM | SpreadsheetAdapter, intern ZIP/XML | SpreadsheetAdapterTests, Stage4FormatTests | reale 2×2-Probe, Makros/Template/Kommentare/Selektion | P07 |
| XLS | SpreadsheetAdapter, Compound/OLE | Fixtures/Spreadsheets/not-word.xls, SpreadsheetAdapterTests | unabhängiger ODS-Vergleich | P07 |
| CSV/TSV | DelimitedTextAdapter, intern | DelimitedTextAdapterTests, reale CSV-Probe | Zeilen/Felder/Unicode, escaped TSV | P07 |
| PPTX/PPTM/POTX | PresentationAdapter, intern ZIP/XML | PresentationNotebookTests, PresentationLinkTests | Folien/Notizen/Bilder/Reihenfolge/Auswahl | P07 |
| ODP | PresentationAdapter, intern ZIP/XML | PresentationNotebookTests | Folien/Notizen/Bilder/Reihenfolge | P07 |
| IPYNB | NotebookAdapter, JSON | PresentationNotebookTests, reale Probe | Markdown/Code/gespeicherte Ausgabe/Bilder; nichts ausführen | P07 |
| ODM | OpenDocumentMasterAdapter, Pandoc | OpenDocumentMasterAdapterTests | lokale Unterdokumente/Reihenfolge/sichere Verweise | P07 |
| HTML/HTM/XHTML | PandocTextAdapter, Pandoc | PandocTextAdapterTests/HTML*Tests | Assetbestand, Remote-Sperre, Verlustdiagnosen | P06 |
| Webarchive | PandocTextAdapter, Pandoc | WebArchiveReaderTests | eingebettete lokale Ressourcen, keine entfernten Downloads | P06 |
| EPUB | PandocTextAdapter, Pandoc | EPUBSelectionTests, PandocTextAdapterTests | Spine/Reihenfolge/Bilder/Kapitelauswahl | P06 |
| LaTeX/TEX | PandocTextAdapter, Pandoc | PandocTextAdapterTests | Text/Assets, input-Pfadschutz | P06 |
| DocBook/DBK | PandocTextAdapter, Pandoc | PandocTextAdapterTests | Struktur/Text; XML-Signatur auch ohne Katalogendung | P06 |
| Org | PandocTextAdapter, Pandoc | PandocTextAdapterTests | Text/Listen/Links | P06 |
| MediaWiki/WIKI | PandocTextAdapter, Pandoc | PandocTextAdapterTests | Text/Listen/Links | P06 |
| Textile | PandocTextAdapter, Pandoc | PandocTextAdapterTests | Text/Listen/Links | P06 |
| reStructuredText/RST | PandocTextAdapter, Pandoc | PandocTextAdapterTests | Text/Listen/Links | P06 |
| FictionBook/FB2 | PandocTextAdapter, Pandoc | PandocTextAdapterTests | Kapitel/Bilder/Links | P06 |
| EML/EMLX | MailAdapter, Pandoc | MailContentTests/MailAdapterTests | Header/MIME/Anhänge/Encoding | P08 |
| MSG | MSGAdapter, Pandoc | MSGMessageTests/MSGAdapterTests | Compound-Inhalt/Anhänge/HTML | P08 |
| MBOX Datei/Paket | MBOXAdapter, Pandoc | MBOXReaderTests, CollectionOutputTests, reale 2er-Probe | Nachrichtenzahl/Reihenfolge/Assets; echte Consumer-Lücke | P08 |
| ENEX | ENEXAdapter, Pandoc | ENEXReader/Resource/ConversionTests, reale 2er-Probe | Notizanzahl/Titel/Assets/Diagnosen; echte Consumer-Lücke | P08 |
| PDF | PDFAdapter, PDFKit/Vision | PDFAdapter/Quality/Structure/Annotation/SelectionTests | Text/Positionen/Seiten/Bilder/Annotationen; Poppler prüfen | P09 |
| PNG/JPG/JPEG/HEIC/TIF/TIFF/GIF/BMP/WEBP | ImageAdapter, ImageIO/Vision | ImageAdapter/VerifiedImageSource/Stage4FormatTests | Byteerhalt/Frames/Orientation/Limits; Decoder+HEIC prüfen | P09 |

Nicht allein Endungslisten verwenden: supportedFormatDescriptors und
DocumentConverter-Registrierung sind Quelle für verfügbare Adapter.

| Querschnitt | Quelle / Fixture | Abnahme / Grenze | Paket |
|---|---|---|---|
| Auswahl | ContentSelectionView, ContentSelection, *SelectionTests | PDF-Seiten/EPUB-Kapitel/Folien/Blätter/Zellrechtecke, Originalpositionen | P06/P07/P09/P14 |
| Profile | ConversionProfile/Store, CLIProfiles, ProfileControls, ConversionProfileTests | Schema1, Defaults, Roundtrip, Bindungs-SHA/Bytes, lokale Pfade opt-in, 0600/0700 | P14 |
| Bericht/Mapping | ConversionReport, ConversionReportTests | Schema1, unabhängige Output-Hashes, UTF8-Bytebereiche, unknown identity, Limits | P14 |
| Diagnosen | ConversionWarning, docs/DIAGNOSTICS.md | information/approximation/contentLoss, Ortsbindung/Gruppen, unbekannte Codes | alle |
| CLI | CLIArguments/Execution/Output, CLI*Tests | JSON/stdout-Konflikte, Batch/jobs1..4, Ordner, Textbundle, Limits/Abbruch | P06/P15 |
| GUI | ContentView:201,260,310,367,450,473-514,549,587-596 | Auswahl/Drop, Start/Abbruch, Fehler-Retry, Zwischenablage, Optionen, Sammlungsübersicht, Preview/Compare, Report, Fastra öffnen | P12/P14 |
| Profile-GUI | ProfileControls:55-136 | Speichern/Duplizieren/Update/Reload/Delete, Bindung und lokale Ziele | P14 |
| Sichere Vorschau | MarkdownPreview*, RenderedMarkdownPreview, ContentView | HTML als Text, Links deaktiviert, Originalvergleich | P12 |
| Clipboard/Services/Shortcuts | PoorMansTextAppSupport, RichTextClipboard, ConvertWithProfileIntent, ServicesProviderTests | tatsächlich verwendetes Clipboard-Format, lokale AppIntents-Entsprechung | P14 |
| Ausgabe/Assets | MarkdownPostprocessor, CollectionPostprocessor, CollectionOutputTests | eigenes Staging, Kollision, kompletter Baum, relative Links nach Prozessende | P03/P06/P08/P13 |
| Fastra | originale MarkdownImport*.swift; Harness | JSON/Katalog/Pfadguard real geprüft; UI und echte App-zu-App-Übernahme offen | P01/P13 |

GUI-Layout, alle nicht ausgeführten Formatfälle, vollständige Report-Optionsabnahme,
Performance/RAM/Abbruchzeitmessung und vollständiger gepaarter Mac-/Linux-Korpus
bleiben ausdrücklich offen. P00/P01 sind deshalb nicht als vollständig bestanden
zu markieren. Keine P05-Produktion und keine Fastra-Änderung erfolgt.


Die reproduzierbaren Referenzproben und normalisierten Antworten liegen unter
[`scripts/linux-probes/contract`](../../scripts/linux-probes/contract).
Temporäre Mac-Pfade sind auf `/fixture/pmt-p01` normalisiert; Inhalte und Hashes
bleiben unverändert. `verify-baseline.py <PMT-Repository>` prüft die gespeicherten
Belege gegen die vorhandenen DOCX-/PNG-Referenzen. Die Binary-Zuordnung zum
Quellcommit bleibt offen. Nächste Ergänzung bei der P05-Entscheidung: vollständiger
Mac-Abnahmekorpus und Build-Provenienz.
