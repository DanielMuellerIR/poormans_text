# Poor Man's Text — Roadmap

Hier steht nur offene Produktarbeit und bewusst gesetzte Formatgrenzen.
Erledigte Punkte werden beim Release aus dieser Datei entfernt und in
[CHANGELOG.md](CHANGELOG.md) festgehalten.

Die formatneutrale Engine, sichere Inhaltserkennung und wählbare dauerhafte oder
temporäre Veröffentlichung sind vorhanden. RTF, RTFD, DOCX/DOCM/DOTX/DOTM,
ODT, DOC, ODS, XLSX/XLSM/XLTX/XLTM, XLS, CSV/TSV, ODM, PDF, PPTX/PPTM/POTX,
ODP, IPYNB, HTML, Webarchive,
EPUB, LaTeX, DocBook, Org, MediaWiki, Textile, reStructuredText, FictionBook
sowie EML, MSG, Apple Mail, MBOX, ENEX und PNG, JPEG, HEIC, TIFF, GIF, BMP und
WebP sind implementiert. Ihre Importwege stehen in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Linux-Portierung

Offen sind die Prüfung weiterer Distributionen und breitere natürliche
Vergleichskorpora für PDF, HEIC und RTFD. Die optionale strukturierte OCR
kann Zeichen, Tabellenzellen und Diagramme verlieren. Eine öffentliche
Verteilung der optionalen Modelllaufzeit setzt eine Prüfung ihrer Lizenzen
und Quellangebote voraus. Die [Release-Abnahme](docs/releases/0.41.24-verification.md)
dokumentiert die geprüften Desktop-, Paket- und Belegabläufe.


## Offene Qualitätsprüfung

### Strukturierte lokale Dokumenterkennung

- Den begrenzten Vergleich vor einem Standardwechsel an natürlichen Scans und
  Fotos erweitern; Inhaltsbestand, Zellzuordnung, Lesereihenfolge, Laufzeit
  und Speicherbedarf entscheiden über seinen Einsatz.

## Mögliche spätere Erweiterung

Eine Vorplanung von Stapelläufen mit Zielübersicht und früher Auflösung von
Namenskollisionen sowie eine Warteschlange für zusätzliche Dateien können
sinnvoll sein. Beides gehört derzeit nicht zum Umsetzungsumfang.

## Belegdaten

- Den Vergleich der Feldregeln auf weitere Layouts freigegebener Rechnungen
  und Lieferscheine ausweiten. Belege mit vertraulichen Daten bleiben lokal.
- Positionstabellen im PDF anhand von markiertem Tabellenkopf und Beispielposition
  einrichten. Spalten vorschlagen und ihre Grenzen im PDF korrigieren lassen.
  Tabellen mit und ohne Gitterlinien, mehrzeilige Beschreibungen, wiederholte Köpfe,
  über Seiten fortgesetzte Positionen, Überträge und Summen getrennt abnehmen.
- MwSt.-Sätze und Skontobedingungen als eigene Felder erfassen. Gedruckte Beträge
  samt Fundstellen erhalten und mit den Positionen vergleichen.
- XML als zweiten Export desselben Ergebnisses ergänzen. Frei gewählte Feldnamen
  als Attribut oder Inhalt eines festen Elements abbilden, Positionen wiederholen
  und fehlende von absichtlich leeren Werten unterscheiden. Sonderzeichen über
  den XML-Serializer behandeln. Für CSV eine ausdrücklich ausgewählte Tabelle
  über den Stapel exportieren, etwa alle Rechnungspositionen.
- Dieselbe Maske auf gescannte und gemischte PDFs anwenden. OCR-Fundstellen in
  denselben Seitenraum überführen, Herkunft sichtbar machen und Konflikte
  zwischen OCR und eingebettetem Text zur Prüfung melden. Weitere strukturierte
  Eingabeformate danach ergänzen.

## Weitere offene Produktarbeit

- RTF: Fortlaufende Nummerierung über verschachtelte Aufzählungen hinweg
  erhalten. Pandoc zerlegt solche Listen teilweise in getrennte Listen mit
  erneutem Startwert; Text und Reihenfolge bleiben erhalten.
- Homebrew-Cask veröffentlichen oder bei Homebrew einreichen. Ein geprüfter
  Entwurf liegt unter `packaging/homebrew/Casks/poor-mans-text.rb`.

### Nicht geplant

- Gegenrichtung Markdown nach DOCX/PDF/ODT: Pandoc könnte es, aber es verändert
  die Positionierung als Import-Werkzeug und verwischt die Fastra-Grenze. Erst
  nach den Etappen 1 bis 5 neu bewerten.
- XLSB (undokumentiertes Binärformat, selten) und MHTML (auf dem Mac selten).

### iWork-Formate (Pages und Numbers) — bewusste Grenze

Entscheidung vom 2026-07-29: kein iWork-Import. Weder Pandoc noch `textutil`
lesen iWork-Dateien. Ohne die installierten Apple-Apps bliebe nur das
Reverse-Engineering des undokumentierten IWA-Formats. Ein Importweg, der Pages
oder Numbers voraussetzt und per AppleScript nach DOCX beziehungsweise XLSX
exportiert, lohnt den Aufwand nicht. Wer eine Pages-/Numbers-Datei umwandeln
will, exportiert sie in der jeweiligen Apple-App als DOCX beziehungsweise XLSX
und nutzt den normalen Import. Keynote fällt unter dieselbe Grenze.

## Fastra-Integration

Die Seite von Poor Man's Text ist erledigt: `poormans-text --formats [--json]`
veröffentlicht den Formatkatalog samt Endungen, Ablageform und
Werkzeugverfügbarkeit, sodass Fastra beim Öffnen entscheiden kann, ohne eigenes
Formatwissen zu pflegen. Fastra ruft die CLI mit einem eigenen Ziel auf, fragt
vorher sichtbar nach und lässt Quelle und erzeugtes Markdown getrennt.

Offen bleibt auf der Seite des Hosts:

- Warnungen und Formatverluste vor dem Öffnen zusammenfassen. Fastra bekommt sie
  bereits über `--json`; die Darstellung liegt beim Host.
- Eine direkte Library-Anbindung prüfen, falls Fastra typisierte
  Fortschrittscallbacks statt CLI-Ausgabe benötigt. Die CLI bietet bereits
  `--progress` und Abbruch über SIGINT/SIGTERM; deren Nutzung entscheidet der Host.

## Technische Referenzen

- [Apple Vision](https://developer.apple.com/documentation/vision) — lokale
  Text- und Dokumenterkennung in Bildern.
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit/pdfdocument) —
  Seiten, Textauswahl und PDF-Verarbeitung.
