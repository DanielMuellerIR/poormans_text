# Folien und Notizen auswählen

PPTX, PPTM, POTX und ODP verwenden dieselbe Auswahl in CLI und Library:

```sh
poormans-text --list-slides --json slides.pptx
poormans-text --slides 1,3-5 --notes off slides.pptx
poormans-text --slides 2 --notes on --report slides.odp
```

Ohne Auswahl werden weiterhin alle Folien einschließlich ihrer Notizen
übernommen. `--slides` verwendet einsbasierte geschlossene Intervalle und
Einzelnummern. Mehrfach genannte Folien werden dedupliziert. Die Ausgabe folgt
der Präsentationsreihenfolge, nicht der Reihenfolge oder dem Namen der
XML-Dateien im Paket. Überschriften, Diagnosen und Quellzuordnungen behalten
die ursprünglichen Foliennummern. Leere, rückwärts laufende oder außerhalb der
Präsentation liegende Bereiche sind Fehler; es gibt keine stille Teilübernahme.

`--notes off` schließt Notiztexte, Tabellen und Bilder vor ihrer Übernahme aus.
`on` erhält die bisherige Notizübernahme. Formate und Bilder werden wie bisher
angenähert und fehlende ausgewählte Ressourcen diagnostiziert. Ein identisches
Bild wird auch bei mehreren Folien-/Notizverweisen nur einmal abgelegt.
Ausgeschlossene Inhalte erzeugen weder Verlustdiagnosen noch ungenutzte Assets.
Dokumentweite Layout- und Makrohinweise bleiben gültig; Makros werden nie
ausgeführt oder übernommen.

Die vollständige ZIP-Prüfung einschließlich ausgeschlossener Medieneinträge
bleibt verbindlich. Auswahl und Notizmodus umgehen weder Pfadschutz noch
Prüfsummen oder Paketbudgets. ODP benötigt weiterhin den begrenzten XML-Baum
seiner gesamten Inhaltsdatei; Text-/Ausgabe- und Assetbudgets betreffen danach
die ausgewählten Inhalte. Fortschritt zählt ausgewählte Folien, Quellenbytes
und vorhandene Ausgabeordner bleiben geschützt.

## Inhaltsübersicht

`--list-slides` verlangt genau eine Präsentation und erlaubt keine
Konvertierungsoptionen. Die Übersicht erzeugt keinen Ergebnisordner und
dekodiert oder speichert keine Bilder. Sie prüft das vollständige Paket und
liest maximal die ersten 200 Folien. JSON liefert Gesamtzahl,
`slidesTruncated`, ursprüngliche Nummern, einen begrenzten ersten Textabsatz
als Titel, lokale Notizverweise sowie die überprüfbare Quellenidentität.
`hasNotes` belegt einen vorhandenen lokalen Notizteil beziehungsweise
ODP-Notizcontainer; es garantiert keinen nicht leeren Notiztext.

Titel sind auf 256 UTF-8-Bytes begrenzt. Für maschinelle Auswertung JSON nutzen;
Textausgabe kann Zeilenumbrüche aus Titeln enthalten. Eine begrenzte
Textübersicht meldet die Begrenzung zusätzlich auf stderr. Die App-Auswahl
wird separat ergänzt.

## Library und Bericht

`ConversionOptions.presentationSelection` übernimmt `PresentationSelection`
mit optionalem `IndexSelection` und `includeNotes`. `nil` erhält das bisherige
Verhalten. `DocumentConverter.inspectPresentationContents` liefert
`PresentationContentSummary`; der Aufrufer kann die Übersicht auf 1 bis 500
Folien begrenzen. Abbruch und Prozessfristen folgen den vorhandenen
Library-Einstiegspunkten. Ein optionaler Konvertierungsbericht speichert die
Auswahl und ursprünglichen Folienzuordnungen.
