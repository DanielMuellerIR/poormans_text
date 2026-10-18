# DOCX-Kommentare und Textänderungen

DOCX einschließlich DOCM/DOTX/DOTM bietet drei gemeinsame Modi in App, CLI und
Kurzbefehlen. `accept` bleibt Vorgabe: eingefügten Text übernehmen, gelöschten
Text weglassen. `reject` erhält den vorherigen Textstand. `mark` erhält beide
Varianten mit sichtbaren Anfangs-/Endmarkierungen und vorhandenen Autoren- und
Datumsangaben. Verschobener Text erscheint bei Annehmen/Verwerfen einmal, bei
Markieren an beiden Positionen. Markierungen für Absatzumbrüche bezeichnen den
Umbruch, nicht pauschal den ganzen Absatz. Eingefügte/gelöschte Tabellenzeilen
folgen derselben Moduswahl.

```sh
poormans-text --docx-changes reject --report review.docx
poormans-text --docx-changes mark --textbundle review.docx
```

Die App merkt sich „DOCX-Textänderungen“ in ihren Konvertierungsoptionen; die
native Kurzbefehle-Aktion bietet denselben Parameter. Der Bericht nennt die
angeforderte Wahl unter `options.docxChangeMode`. Alte Berichte ohne dieses Feld
bleiben lesbar. Die Option gilt ausschließlich für DOCX: ODT und das binäre DOC
behalten ihre bisherigen Importwege und Grenzen.

## Kommentare und Quellbezug

Kommentare bleiben in allen drei Modi als eigene Textanmerkungen erhalten.
Sichtbare Bereichsanfänge, Bereichsenden und Punktverweise tragen eine gemeinsame
Kommentarnummer. Unter „Document comments“ stehen die ursprüngliche Kommentar-ID,
vorhandener Autor und Zeitstempel, ein Quellenauszug und der Kommentartext.
Moderne `w16du:dateUtc`-Zeitangaben bleiben zusätzlich zum ursprünglichen
`w:date` erhalten; Zeitzonen werden nicht geraten oder umgerechnet.
Mehrere überlappende Kommentare behalten getrennte Markierungen. Kommentare an
Bildern erhalten einen Bildbezug; Kommentare in Fuß-/Endnoten behalten ihren
Notenteil als Fundstelle. Vorhandene Notennummern werden nicht als Kommentar-IDs
wiederverwendet.

Entfernt der gewählte Änderungsmodus den Ankertext, bleiben Kommentar und
verfügbarer Quellenauszug separat erhalten; eine Diagnose erklärt den fehlenden
Anker. Dasselbe gilt für verwaiste Definitionen oder nicht konvertierte Bereiche.
Fehlende Definitionen und unvollständige/wiederholte Bereiche werden konkret
gemeldet. Es wird kein zusammenhängender Bereich erfunden. Der Auszug hat
höchstens 1.024 Zeichen und ist ausdrücklich kein vollständiges Quellzitat.
Bericht und Quellzuordnung beziehen sich auf die unveränderten Originalbytes
und bekannte Absatz-/Notenpositionen. Fuß-/Endnoten und tatsächlich verwendete
Bildassets bleiben erhalten.

Kommentartext und importierte Metadaten bleiben literal: enthaltene Markdown-
oder HTML-Zeichen eröffnen keine neuen Links, Bilder oder Formatierungen.
Kommentarformatierung wird zu Text abgeflacht. Tabellen/Hyperlinks, grafische
Objekte und Notenverweise innerhalb von Kommentaren erhalten bei entsprechenden
Verlusten eine Diagnose. Antwortbeziehungen und Erledigt-Zustände moderner
Kommentar-Threads werden nicht rekonstruiert; ihre Kommentartexte bleiben
einzelne Anmerkungen.

## Verarbeitung und Grenzen

`DOCXReviewPreserver` bearbeitet ausschließlich die bereits vollständig geprüfte
private Paketkopie. Zufällige interne Textmarker tragen Anker und sichtbare
Revisionen durch DOCX → HTML → Markdown. Erst danach werden sie durch bewusst
erzeugte Markierungen ersetzt. Pandoc-Spanklassen allein würden diese Bedeutung
in der Schlussstrecke verlieren. Doppelte oder beschädigte interne Marker führen
zu einem Fehler statt zu einer falschen Zuordnung.

Pandoc liest Notenteile unter festen Namen und übernimmt aus einem Textlauf nur
einen Notenverweis. Die Vorbereitung trennt mehrere Verweise und normalisiert
abweichend benannte Notenteile samt lokalen Beziehungen in der privaten Kopie.
Widersprechende vorhandene Aliasdateien führen zu einem verständlichen Fehler.
Quellen werden weder gespeichert noch umbenannt; vorhandene Ergebnisse werden
nicht überschrieben. Das gesamte Ergebnis entsteht vor atomarer Veröffentlichung.

Historische Formatierungen, Zelleigenschaften und komplexe Strukturänderungen
lassen sich in Markdown nicht vollständig rekonstruieren. Aktueller lesbarer
Inhalt und verfügbare Revisionsmetadaten bleiben erhalten; Diagnosen nennen
diese Grenze. Nicht an ihrer Position ausgegebene markierte Revisionen erhalten
eine separate Textanmerkung. Kopf-/Fußzeilen und andere von Pandoc nicht gelesene
Dokumentbereiche werden dadurch nicht zu vollständig unterstützten Inhalten.

Die zusätzliche Verarbeitung ist begrenzt: 16 MiB pro XML-Eintrag, 32 MiB für
Haupttext und Notenteile zusammen, 4.096 Kommentare, 32.768 Marker, 10.000
Revisionseinträge, eine Million Kommentar-Kontextzuordnungen sowie jeweils
8 MiB für Marker, Revisionsinformation und ausgegebene Anmerkungen. Das fertige
Markdown darf 64 MiB nicht überschreiten. Bestehende ZIP-/XML-Grenzen, lokale
Ressourcenprüfung, Werkzeugfristen und Abbruch gelten weiterhin. Ein Fehler
veröffentlicht kein partielles Ergebnis.

## Reproduktion

```sh
swift test --filter 'DOCXReviewTests|WordProcessingAdapterTests|WordProcessingPackageInspectionTests|ShortcutConversionTests|CLIOutputModeTests'

review_dir=$(mktemp -d /tmp/poormans-docx-review.XXXXXX)
PMT_DOCX_REVIEW_DIR="$review_dir" \
  swift test --skip-build --filter DOCXReviewTests/testRealDOCXModesPreserveCommentsNotesTablesAndImageBytes
```

Der zweite Lauf erzeugt eine echte synthetische DOCX sowie Ausgaben und eine
gezählte Matrix für alle drei Modi. Er prüft überlappende und entfernte
Kommentaranker, Autor/Datum, eingefügte/gelöschte Absätze, Tabellenzeilen,
verschobenen Text, Fuß-/Endnoten, Bildbytes, Originalhash und Berichtsmappings.
Weitere Fälle prüfen Punkt-/unvollständige Anker, abweichende Kommentar-/Notenteile
einschließlich Notenbildern, ungültige/entfernte Beziehungen, doppelte IDs,
Ressourcenüberschreitung, literal behandelte Metadaten und Textbundle-Zuordnung.

Primärquellen: [Pandoc-Handbuch](https://pandoc.org/MANUAL.html#option--track-changes),
[Pandoc-DOCX-Leser 3.12.1](https://github.com/jgm/pandoc/blob/3.12.1/src/Text/Pandoc/Readers/Docx/Parse.hs)
und [WordprocessingML-Kommentare](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.comment)
sowie [UTC-Datumsattribute](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.linq.w16du).
