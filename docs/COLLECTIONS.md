# Ausgabe von Dokumentensammlungen

Eine Sammlung entsteht aus einer Quelle und wird als ein vollständiges Ergebnis
veröffentlicht. Ihr `markdownFile` bleibt der primäre Einstieg: eine Übersicht mit
relativen Links auf die Dokumente in Quellreihenfolge. Derselbe kleine Vertrag ist
für Mailarchive und Notizexporte vorgesehen; die unterstützten Eingabeformate
werden weiterhin im Formatkatalog ausgewiesen.

## Ergebnis und JSON

`ConversionResult.documents` enthält `ConversionDocument`-Werte mit `sourceIndex`
(ab 1), Titel, `markdownFile`, zugehörigen `assets` und `metadata`. Bei einer
Einzeldatei enthält die Liste genau den bisherigen primären Eintrag. Bei einer
Sammlung stehen dort die Einzeldokumente; die Übersicht bleibt separat über
`result.markdownFile` erreichbar. `isCollection` unterscheidet auch eine leere
Sammlung von einem gewöhnlichen Einzeldateiergebnis.

CLI-Erfolgsantworten und Batch-Einträge ergänzen `documents` mit denselben Angaben.
Die bisherigen Felder behalten ihre Bedeutung: `markdownFile` ist primär,
`assets` umfasst alle Zusatzdateien des primären Einstiegs, also bei Sammlungen
auch die verlinkten Markdown-Dokumente. Bestehende Hosts können dadurch weiterhin
den Einstieg samt seinen Assets übernehmen. Die Assetliste eines Einzeldokuments
enthält dessen eigene Bild-/Anhangsdateien. `outputDirectory` bezeichnet die ganze Ausgabe.
Metadaten verwenden in JSON weiterhin ISO-8601-Daten. Der optionale Bericht bleibt
Schema 1; seine additive Dokumentliste verwendet relative Markdown-/Assetpfade.
Ältere Berichte ohne diese Liste bleiben lesbar.

## Dateien und Textbundle

Nummerierte Unterordner vermeiden Kollisionen auch bei gleichen Titeln, gleichen
Assetnamen und Unicode-Varianten. Titel werden als wörtlicher Markdown-Text
geschrieben; sie werden nicht zu Dateipfaden. Ein Markdown-Ordner sieht etwa so aus:

```text
archive-markdown/
  index.md
  assets/documents/000001/
    archive.md
    images/image01.png
    attachments/file.bin
  assets/documents/000002/
    archive.md
    images/image01.png
  conversion-report.json       # nur mit Bericht
```

Textbundle verwendet dieselben internen Dokumente und Assets. Die Übersicht heißt
`text.md`, zusätzlich entsteht `info.json` nach Version 2. Vom Haupttext
referenzierte Dateien liegen unter `assets/`, wie in der
[Textbundle-Spezifikation](https://textbundle.org/spec/) vorgesehen. Bekannte
Rückverweise aus Einzeldokumenten auf die Übersicht werden auf `text.md` angepasst;
wörtlicher Code bleibt unverändert.

Frontmatter wird, wenn gewünscht und vorhanden, für Übersicht und Einzeldokumente
aus deren eigenen Metadaten erzeugt. Das Ausgabemanifest umfasst alle Markdown-
und Assetdateien. Verfügbare Quellenbezüge eines Einzeldokuments zeigen auf seine
Datei und deren endgültige UTF-8-Bereiche; lokale Offsets werden nicht der
Übersicht zugeordnet.

## Ausgabeaktionen

Öffnen und Vorschau verwenden weiterhin die primäre Übersicht. Ein Editor kann
deren relative Dokumentlinks innerhalb des Ausgabeordners öffnen. Die sichere
App-Vorschau aktiviert weiterhin keine Dokument- oder externen Links. Kopieren
übernimmt die Übersicht; die vorhandene Meldung zu nicht kopierten Zusatzdateien
und relativen Links bleibt wirksam. Einzeldokumente benötigen den Ausgabeordner.

`--stdout` weist jede Sammlung vor der ersten Textausgabe ab, auch eine Sammlung
mit nur einem Dokument. So werden keine Links auf anschließend entfernte
temporäre Dokumente ausgegeben. Ein Ausgabeordner oder Textbundle erhält die
vollständige Sammlung.

## Grenzen und Veröffentlichung

Alle Dokumente werden unter demselben privaten Staging-Dach fertiggestellt und
genau einmal atomar veröffentlicht. Ein später Fehler, Abbruch, fehlendes Asset
oder eine Zielkollision veröffentlicht keine Teilsammlung. Unveränderte Quellen
und vorhandene Ausgabeordner bleiben geschützt.

Die gemeinsame Schlussstrecke begrenzt eine Sammlung auf 10.000 Dokumente,
16 MiB Markdown je Einzeldokument, insgesamt 256 MiB Markdown einschließlich
Übersicht und Frontmatter, 512 MiB Assets, 100.000 Assetdateien und 250.000
Verzeichniseinträge einschließlich Ordnern. Titel haben
höchstens 4.096 UTF-8-Byte, Metadaten je Dokument 64 KiB; Metadaten und Fundstellen
zusammen höchstens 16 MiB. Adapter können engere Eingabegrenzen setzen. Fehlende,
doppelt gemeldete, nicht gemeldete oder über symbolische Verweise ausgelagerte
Ausgabedateien werden abgewiesen. Verschachtelte Sammlungen sind nicht vorgesehen.
