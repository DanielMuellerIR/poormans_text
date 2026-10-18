# Poor Man’s Text und Microsoft MarkItDown

Stand: 2026-10-18, Poor Man’s Text 0.41.2.

[Microsoft MarkItDown](https://github.com/microsoft/markitdown#readme) beschreibt
sich als Python-Werkzeug für Markdown-Aufbereitung in Sprachmodell- und
Textanalyse-Pipelines. Die offizielle README dokumentiert Office-, PDF-, Bild-
und weitere Eingaben, stdin/stdout, optionale Modellanbindung und Plugins.
Diese Angaben wurden am oben genannten Datum geprüft; ein gemeinsamer
Qualitäts- oder Geschwindigkeitstest wurde nicht durchgeführt.

Poor Man’s Text bietet eine macOS-App und CLI über einem gemeinsamen Swift-Kern.
Die Konvertierung verarbeitet lokale Dateien, erhält unterstützte Bilder und
Anhänge als separate Assets und veröffentlicht vollständige Ausgabeordner oder
Textbundles atomar. Pandoc bleibt für die im Formatkatalog genannten Formate
nötig. Lokale Vision-OCR ergänzt Bild- und PDF-Importe ohne Modellserver.

## Stand der früheren Vorschläge

Die frühere Analyse nannte folgende Erweiterungen. Sie sind inzwischen umgesetzt
und gehören nicht mehr zur offenen Roadmap:

| Bereich | Aktuelles Verhalten von Poor Man’s Text |
| --- | --- |
| Präsentationen | Nativer PPTX/PPTM/POTX- und ODP-Import mit Text, Tabellen, Notizen, Bildern, Hyperlinks und Folienauswahl. [Details](PRESENTATION-IMPORT.md) |
| Notebooks | IPYNB übernimmt Markdown, Code, gespeicherte Textausgaben und Bilder; Code wird nicht ausgeführt. [Details](NOTEBOOK-IMPORT.md) |
| Standardausgabe | `--stdout` gibt ein einzelnes Dokument nach temporärer Konvertierung aus. Assets bleiben nicht erhalten; Sammlungen werden abgewiesen. stdin ist kein Eingabeweg. [CLI-Vertrag](../README.de.md#frontmatter-textbundle-und-standardausgabe) |
| Metadaten | `--frontmatter` schreibt verfügbare Quellmetadaten als YAML; JSON enthält sie auch ohne diesen Schalter. [CLI-Vertrag](../README.de.md#frontmatter-textbundle-und-standardausgabe) |
| Mail und Notizen | EML/EMLX und MSG sowie MBOX-/Apple-Mail- und ENEX-Sammlungen werden mit ihren jeweiligen Grenzen unterstützt. [Mail](../README.de.md#e-mail-import), [MBOX](MBOX.md), [ENEX](ENEX.md) |

Weitere vorhandene Funktionen sind EPUB-Import mit Kapitelauswahl,
DOCX-Kommentare und wählbare Textänderungen, PDF-Anmerkungen, benannte Profile,
Quellvergleich und Konvertierungsberichte. Die [README](../README.de.md) und die
verlinkten Formatdokumente beschreiben die aktuellen Grenzen.

## Vergleichsgrenzen

Unterschiedliche Laufzeitumgebungen und Formatadapter begründen allein keine
Aussage über Geschwindigkeit, Speicherverbrauch oder Inhaltsqualität.
Projektmessungen stehen mit ihren Eingaben und Einschränkungen in
[PERFORMANCE.md](PERFORMANCE.md) und [STRUCTURED-OCR.md](STRUCTURED-OCR.md).
Aussagen über andere Werkzeuge sind anhand ihrer aktuellen Primärquellen und
bei Bedarf identischer Testdokumente zu prüfen.

Offene Produktarbeit und bewusste Formatgrenzen stehen ausschließlich in der
[Roadmap](../ROADMAP.md).
