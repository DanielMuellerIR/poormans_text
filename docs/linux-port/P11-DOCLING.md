# P11: Docling-/TableFormer-Kandidat

Fortschreibung für 0.41.17: [Produktintegration und tatsächliche Abnahmen](P16-04117/README.md)
sind inzwischen vorhanden; die allgemeine Inhaltsqualitätsfreigabe bleibt FAIL.
Der nachfolgende Bericht beschreibt ausdrücklich die frühere Entscheidungsprobe.

Stand: 2026-11-05. Der begrenzte CPU-/Offlineversuch macht TableFormer zu einem
begründeten Kandidaten für strukturierte Erkennungsdaten. **Diese Probe enthielt noch keine
Produktintegration oder Gesamtfreigabe von P11.** Swift bleibt der gemeinsame
Kern; der bestehende PDF-Import wird nicht durch Doclings Markdownexport ersetzt.

| Tatsächliche Eingabe | Unverändertes automatisches Ergebnis |
| --- | --- |
| Natürliche PDF-Seite 132 | Alle neun Zelltexte, Zeilen-/Spaltenpositionen und Spans exakt zur Original-GT, einschließlich Kopfzelle über zwei Spalten. |
| Dieselbe Seite als 144-DPI-PNG mit vollständiger Tesseract-OCR | Ebenfalls neun von neun rohen Zelltupeln exakt. Dies ist ein gerasterter Ableger derselben Seite, kein unabhängiger natürlicher Scan. |
| Natürliche Seiten 134 und 135 | Jeweils korrekt keine Tabelle; zwei Negativseiten belegen keine allgemeine Fehlalarmrate. |
| Identisches synthetisches Mac-Fixture | Acht von acht Spans korrekt, fünf von acht Zelltexten exakt. `Al/Bl/Cl` stehen statt `A1/B1/C1`; diese Fehler bleiben sichtbar. |

Die Zell-/Spantupel wurden unabhängig mit einem zweiten GT-HTML-Parser ohne
Normalisierung nachgerechnet. Referenzdaten werden erst nach der unveränderten
Inferenz gelesen. Es gab keine manuelle Region, Schwellenkorrektur oder Änderung
an Modellklassen/Postprocessing. Alle fünf Eingaben und zehn Ergebnisdateihashes
sind geprüft. Die [kleinen Resultate](P11-DOCLING-EVIDENCE/result.json) und die
vollständigen Markdown-/Dokument-JSON-Ausgaben bleiben erhalten.

Der direkte Markdownexport dupliziert die sechs Wörter des verbundenen
Tabellenkopfs und kodiert den `colspan` nicht. Er lässt außerdem Footer weg, die
im Dokument-JSON vorhanden sind. JSON und Markdown wurden deshalb getrennt
bewertet: auf Seite 135 enthält das JSON alle 561 Referenzwörter, Markdown nur
554 passende Wörter. Auf Seite 132 stimmen bei Auswertung der JSON-`text`-Felder 317 von 339 Worttokens; unter
anderem fehlen eingebettete Bildbeschriftungen, und `in-house` wird `inhouse`.
Der zusätzliche Rasterlauf verändert auch die Caption-Reihenfolge. Die gute
Tabellenprobe ist keine bestandene Gesamtdokument- oder OCR-Textparität.

Die bereits vorhandene PMT-spezifische Markdown-Zellprüfung sucht nur vor der
Tabellencaption und passt nicht zu Doclings Rasterexport mit Caption vor der
Tabelle. Ihr anfängliches Nullzellenergebnis wurde als ungeeigneter Prüfscope
entfernt, nicht als Modellverlust ausgegeben. Die belastbaren neun Zellen stammen
aus dem unveränderten Erkennungs-JSON. `orig` und `text` werden nicht addiert.

Der echte Stand verwendet Docling2.147.0, IBM-models4.0.4, CPU-Torch2.8.0,
Transformers5.22.1, Heron und TableFormer accurate. Ausschließlich fünf
revisions-/SHA256-gebundene Safetensors-/Configdateien sind vorhanden. Der
TableFormer-Loader benutzt Safetensors; Heron den eingebauten RTDetrV2-Typ ohne
Remote-Code. Downloads finden ausschließlich im ausdrücklichen Setup statt.
Inferenz läuft mit Netzsperre, UID1000, read-only Root/Modelldaten, zwei CPUs,
4 GiB Speicher, 256 PIDs und 180 Sekunden je Fall. Gemessen wurden ungefähr
4–10 Sekunden Inferenz und bis etwa 1,1 GiB Prozess-RSS; Interpreter-/Importstart
kommt hinzu. Cgroup-Charge und RSS sind unterschiedliche Größen und werden
separat erhalten. Diese Einzelmessungen sind keine Produktleistungszusage.

Das zusätzliche Setup blieb mit 847.739.690 konservativ erfassten Bytes unter
1 GiB. 72 Wheels umfassen 382.503.908 Bytes, Modelle/Configs 384.428.156 Bytes;
APT-/Pip-Metadaten und Reserve sind zusätzlich berücksichtigt. Der ursprüngliche
Wheel-Zwischenwert wurde nach der Rtree-/SciPy-Ergänzung aus dem vollständigen
Manifest korrigiert. Fehlendes `convert-core` war ein Setupfehler. Zwei
ungeeignete tmpfs-Exportversuche wurden durch Sicherung im laufenden Container
ersetzt; keine davon verändert Inferenz oder Ground Truth.

Modelle sind laut offiziellen Karten CDLA-Permissive2.0 beziehungsweise Apache2.0;
Docling und IBM-models sind MIT. In 44 der 72 Wheelmetadaten fehlen beide
Lizenzfelder. Das ist keine Distributionsfreigabe. Quellen-/Native-Lizenzprüfung,
Modellinstallation/Updates und reproduzierbare sichere Produktpaketierung sind
weiter eigene Tore. Gewichte und Wheels liegen nicht im Repository.

**Empfehlung:** Doclings typisierte Erkennungsdaten als nächsten P11-Adapter prüfen.
Der vorhandene Swift-Renderer muss vollständige Textinventare, Zellen/Spans,
Quellzuordnung und Verlustdiagnosen erhalten. Vor Integration fehlen breitere
natürliche Scans/Fotos, vertikale Spans, mehrspaltige Lesereihenfolge, weitere
Sprachen sowie ein belegter Produktpfad mit denselben Snapshot-, Netz-, Prozess-,
Speicher- und Ausgabebudgets. Standard-PDF-Text und Assets bleiben im Swift-Pfad.
Der aktuelle Produktstand meldet strukturierte OCR weiterhin als unavailable.

[Reproduktionsrezept](../../scripts/linux-probes/p11/docling/README.md),
[offizieller Docling-Stand](https://github.com/docling-project/docling/releases/tag/v2.147.0),
[Safetensors-Loader](https://github.com/docling-project/docling-ibm-models/blob/v4.0.4/docling_ibm_models/tableformer/data_management/tf_predictor.py),
[Offlinebetrieb](https://docling-project.github.io/docling/usage/advanced_options/#model-prefetching-and-offline-usage),
[TableFormer-Modellkarte](https://huggingface.co/docling-project/docling-models/blob/fc0f2d45e2218ea24bce5045f58a389aed16dc23/README.md),
[Heron-Modellkarte](https://huggingface.co/docling-project/docling-layout-heron/blob/8f39ad3c0b4c58e9c2d2c84a38465abf757272d8/README.md).

Der eigene Probecontainer und beide eigenen Modellimages wurden nach der
Belegsicherung entfernt; Gewichte/Wheels bleiben nicht als versteckte Laufzeit
zurück. [Cleanup](P11-DOCLING-EVIDENCE/cleanup.json). Das konsolidierte Setuprezept
wurde nach dem Versuch aus den ausgeführten Schritten gebildet, aber nicht
nochmals vollständig gebaut; dies ist keine zusätzliche Reproduzierbarkeitsabnahme.

## Anschlussnachweise nach dem Modellversuch

Die [Swift-Parserprojektion und der frische Mac-Paarvergleich](P11-SWIFT-PROJECTION.md)
sind zusätzlich belegt: vier gespeicherte JSONs passieren unveränderte Core-
Modelle/Renderer,18 beschädigte Varianten werden abgewiesen. Sie bewahren das
autoritative Originaltext-/Zellinventar einschließlich Footer. Die `orig`-Sicht
ist von der früheren `text`-Wortmessung zu unterscheiden; keine beiden Felder
addieren. Der Mac liefert synthetisch7/8 Zelltexte und auf der Naturseite9/9
Zelltexte als Prosa, ohne Tabellenstruktur. Deshalb Qualitätsreferenzen unabhängig
prüfen und keinen Applied-/Projektionsnachweis zur Produktfreigabe hochstufen.
