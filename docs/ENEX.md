# Begrenzter ENEX-Import

Reguläre UTF-8-ENEX-Dateien werden als geordnete Notizsammlung importiert.
Die Übersicht verlinkt die Notizen in Exportreihenfolge. Gleiche Titel erhalten
getrennte nummerierte Dokumentordner. Titel, Tags und vorhandene Erstellungs- und
Änderungsdaten stehen in den Dokumentmetadaten; die Markdown-Datei enthält den
Titel und eine Tabelle der übrigen Quellfelder. Frontmatter ist weiterhin optional.
Die Quellposition `note` bezeichnet die laufende Notiznummer ab 1. Der Bericht
enthält den Hash des vollständigen unveränderten Exports.

```sh
poormans-text --json --report notes.enex
poormans-text --textbundle notes.enex
```

Die Ausgabe folgt dem [Sammlungsvertrag](COLLECTIONS.md). stdout ist für
Sammlungen nicht verfügbar. Ein Fehler in irgendeiner Notiz oder ein Abbruch
verwirft die gesamte temporäre Ausgabe; vorhandene Ziele werden nie überschrieben.

## Formate und Inhalt

Der Leser unterstützt die belegten Strukturen von ENEX 2, 3 und 4 sowie ENML 2.
Grundlagen sind die offiziellen [Export-Dokumentation](https://dev.evernote.com/legacy/doc/articles/note_export),
die DTDs [2](https://xml.evernote.com/pub/evernote-export2.dtd),
[3](https://xml.evernote.com/pub/evernote-export3.dtd),
[4](https://xml.evernote.com/pub/evernote-export4.dtd) und die
[ENML-Dokumentation](https://dev.evernote.com/legacy/doc/articles/enml).
Das `version`-Attribut eines Exports benennt die erzeugende App und wird nicht
als zuverlässige Schemakennung verwendet. Feldreihenfolgen aus älteren und neueren
Exporten werden gelesen; doppelte eindeutige Felder werden abgewiesen.

- `en-note` wird über begrenztes lokales HTML in Markdown überführt. Absätze,
  Überschriften, Listen, Tabellen, einfache Hervorhebungen und Code bleiben im
  Rahmen der bestehenden HTML-Konvertierung erhalten. Markierte Evernote-Codeblöcke
  werden zu Code; Code und CDATA werden nicht als weitere Notizstruktur ausgeführt.
- `en-todo` erhält seinen Zustand als statisches ☐ beziehungsweise ☑. Aufgaben
  aus ENEX 4 werden separat als statische Einträge in Exportreihenfolge mit ihren
  Quellfeldern ausgegeben. Gruppierung, Sortierlogik und ausführbare Aufgabenaktionen
  werden nicht nachgebildet und erhalten eine Diagnose.
- `en-crypt` bleibt einschließlich verschlüsseltem Text und verfügbaren Attributen
  wörtlich erhalten. Es wird keine Entschlüsselung versucht.
- Unbekannte ENML-Elemente bleiben als wörtlicher Code mit einer Diagnose erhalten.
  Unbekannte Notizfelder und Attribute stehen in der Quellfeldtabelle. Aktive
  Elemente wie Skripte werden dabei als Text erhalten und nicht ausgeführt.
- Ungültige Datumswerte werden nicht durch erfundene Daten ersetzt: Das API-Datum
  bleibt leer, der Originalwert steht in der Tabelle und `enex.invalidDate` meldet
  die Einschränkung. Leere Inhalte und leere Sammlungen bleiben explizit leer.

## Ressourcen und interne Verweise

Ressourcen werden streng als kanonisches Base64 mit ASCII-Leerraum dekodiert.
Der MD5 des dekodierten Körpers und sein MIME-Typ bestimmen die `en-media`-
Zuordnung, wie in der [ENML-Spezifikation](https://dev.evernote.com/legacy/doc/articles/enml)
beschrieben. Exportnamen bleiben sichtbare Beschriftungen: Nur Ordinal und
geprüfter Typ bestimmen `attachments/resource-000001.png` und ähnliche Pfade.
Jeder ursprüngliche Ressourcenrecord bleibt separat erhalten, auch bei gleichen
Bytes, Namen oder Hashes. Mehrere Verweise auf identische Rasterbytes teilen sich
zusätzlich eine gerenderte Bildkopie. Ein Hash mit unterschiedlichen Bytes ist
mehrdeutig und erhält keine willkürliche Zuordnung.

PNG, JPEG, HEIC, TIFF, GIF, BMP und WebP werden gegen den tatsächlichen Rastertyp
und die Pixel-/Framegrenzen geprüft. Statische Rasterbilder werden eingebettet;
ihre Originale bleiben zusätzlich als Anhänge erhalten. Mehrseitige oder aktive
Bildformate wie SVG und unbekannte Typen bleiben als `.bin`-Anhänge bytegetreu
erhalten und werden diagnostiziert. PDF-Anhänge werden als lokale PDF-Struktur
geprüft und kopiert, nicht konvertiert oder ausgeführt. UTF-8-Text ohne NUL darf
`.txt` verwenden; andere Typen bestimmen keine ausführbaren Dateiendungen.
Alternative Binärdaten und vorhandener Erkennungstext werden als eigene sichere
Dateien erhalten. Entfernte Ressourcen werden nicht geladen.

Jeder `en-media`-Verweis bleibt einzeln sichtbar. Fehlende Hashzuordnung,
widersprüchlicher Typ oder mehrdeutige Hashes behalten Typ/Hash/Alt-Text als
Platzhalter mit konkreter Diagnose. Die sonstigen Originalanhänge bleiben dabei
verfügbar. Defektes Base64 und ungültige deklarierte Raster-/PDF-Daten scheitern
atomar, ebenso überschrittene Budgets.

Die offiziellen [Note Links](https://dev.evernote.com/legacy/doc/articles/note_links)
identifizieren ihr Ziel über eine GUID. Standard-ENEX lässt diese Notizidentitäten
häufig weg. Der Leser nutzt nur tatsächlich enthaltene eindeutige Notiz-GUIDs:
explizite `guid`-Attribute oder skalare `guid`-Felder direkt an einer Notiz werden
als Exporterweiterung unterstützt. Die Standard-DTDs selbst versprechen diese
Felder nicht. Gleiche oder sogar einzigartige Titel sind kein Identitätsbeleg.
Klassische Evernote-Links und dokumentierte Web-Notizlinks können damit auf die
nummerierte lokale Markdown-Datei zeigen. Fehlende, doppelte oder widersprüchliche
Identitäten und verkürzte Links ohne Offline-Identität bleiben mit Linktext und
wörtlichem Originalziel erhalten und werden diagnostiziert. Ohne exportierte
Identitäten ist eine vollständige Linkmigration nicht möglich.

Sonstige sichere HTTP-, HTTPS- und Mailto-Links bleiben Links. Andere Ziele werden
als Text erhalten. In der App bleibt die Übersicht erreichbar. Die nummerierte Notizwahl und
Titelsuche gelten für Öffnen, Kopieren und Vorschau; gleiche Titel behalten ihre
Exportnummer. Kopieren übernimmt Markdown, nicht die referenzierten Dateien.
Der Bericht umfasst immer alle Notizen, Assets, Metadaten und Diagnosen.
Profile und optionales Frontmatter gelten je Notiz in beiden Ausgabeformen.

App, CLI, Finder-Dienst und beide Kurzbefehle-Aktionen benötigen Pandoc für ENEX.
Kurzbefehle geben den vollständigen Ergebnisordner zuerst zurück, gefolgt von
Diagnosen. ENEX ist eine einzelne lokale Datei, kein Ordnerpaket. Es gibt weder
Evernote-Login noch Sync oder Cloud-Nachladen.

**Lokale Dateien** in der Notizvorschau bietet die registrierten Bilder und
Anhänge dieser Notiz an. Rasterbilder werden begrenzt gerendert, PDFs zeigen
ausschließlich Seite 1 mit Seitenzahl, UTF-8-Text höchstens 256 KiB. Links und
PDF-Aktionen sind inaktiv. Unbekannte/aktive Typen werden nicht ausgeführt; eine
Meldung verweist auf das erhaltene Original im Ausgabeordner. Je Datei gilt
eine Vorschaugrenze von 16 MiB, die Liste zeigt höchstens 1.024 Dateien mit
explizitem Hinweis bei Begrenzung. Die vollständige Ausgabe bleibt erhalten.

## Sicherheits- und Größengrenzen

Die gesamte ENEX-Datei ist auf 16 MiB begrenzt, der ENML-Inhalt einer Notiz auf
8 MiB. Zusätzlich gelten 10.000 Notizen, 1.024 Tags und Aufgaben pro Notiz,
64 KiB Metadaten pro Notiz sowie die gemeinsamen Ausgabe-/Assetgrenzen.
Ressourcen sind auf 12 MiB je Binärpayload, 1.024 Records je Notiz,
10.000 Records und 64 MiB dekodierte Ressourcen-/Begleitdaten je Archiv begrenzt.
Ein gemeinsames Budget erlaubt 64 Millionen geprüfte Rasterpixel über alle
Frames; bytegleiche Daten desselben Typs werden anhand SHA-256 nur einmal geprüft.
Höchstens 1.000 Frames je Bild sind erlaubt.
XML ist auf 128 Ebenen, 200.000 Knoten und Attribute insgesamt, 128 Attribute
pro Element und 1.024 UTF-8-Bytes pro Elementname begrenzt. Der Prolog darf
16 KiB und eine DOCTYPE-Deklaration 4 KiB nicht überschreiten.

Bekannte DOCTYPE-Verweise sind ausschließlich deklarativ und werden vor der
XML-Verarbeitung entfernt. DTDs und externe Entitäten werden nie geladen;
interne Entitätssubsets und fremde Namensräume werden abgewiesen. Benötigte
benannte Zeichenreferenzen stammen aus einer vorhandenen lokalen Tabelle,
CDATA bleibt davon unberührt. Eine zusätzliche Vorprüfung begrenzt die mögliche
ENML-Expansion auf 16 MiB, bevor der Baum oder HTML-Text aufgebaut wird. Sehr
große oder anders strukturierte Exporte scheitern verständlich und atomar.
