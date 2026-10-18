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

## Noch offene Ressourcengrenze

Exportierte `resource`-Elemente werden derzeit mit `enex.resourcesNotImported`
und ihrer Anzahl diagnostiziert. `en-media` bleibt als sichtbarer Platzhalter mit
vorhandenem Typ, Hash und Alt-Text erhalten. ENEX-Bilder und Anhänge sowie die
auflösbaren internen Notizverweise werden in einem weiteren Schritt ergänzt.
Eine Ausgabe mit solchen Diagnosen ist daher keine vollständige Ressourcenkopie.
Die Quelle bleibt erhalten. Gewöhnliche lokale oder eingebettete HTML-Bilder
unterliegen den bestehenden Bildgrenzen; entfernte Bilder werden niemals geladen.

HTTP-, HTTPS- und Mailto-Links bleiben Links. Andere Ziele, darunter interne
Evernote-Verweise, bleiben zunächst als Text mit `enex.linkNotResolved` erhalten.
Es wird keine nicht exportierte Notizidentität erfunden.

## Sicherheits- und Größengrenzen

Die gesamte ENEX-Datei ist auf 16 MiB begrenzt, der ENML-Inhalt einer Notiz auf
8 MiB. Zusätzlich gelten 10.000 Notizen, 1.024 Tags und Aufgaben pro Notiz,
64 KiB Metadaten pro Notiz sowie die gemeinsamen Ausgabe-/Assetgrenzen.
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
