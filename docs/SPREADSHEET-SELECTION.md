# Tabellenblätter und Zellbereiche auswählen

CLI und Library unterstützen XLSX einschließlich makrofähiger Varianten, XLS
und ODS. CSV/TSV haben kein Arbeitsmappenverzeichnis und lehnen diese Auswahl ab.
Ohne Auswahloptionen bleibt die bisherige Übernahme aller lesbaren Arbeitsblätter
einschließlich versteckter Blätter bestehen.

```sh
poormans-text --list-sheets --json workbook.xlsx
poormans-text --sheets visible workbook.xlsx
poormans-text --sheets 1,3-5 --cell-range B2:D8 workbook.xlsx
poormans-text --sheet-name 'Budget 2026' --cell-range A1:C4 --cell-range F10:G12 workbook.ods
```

`--list-sheets` benötigt genau eine Arbeitsmappe, erzeugt keinen Ausgabeordner
und erlaubt keine Konvertierungsoptionen. JSON liefert den Quellenhash sowie
Quellindex, Namen, Sichtbarkeit und Lesbarkeit jedes Blattes. Textausgabe ist
für Menschen gedacht; Namen können Tabulatoren oder Zeilenumbrüche enthalten.
Die Übersicht liest die gesamte Quelle innerhalb der bestehenden Importbudgets.
Die App-Auswahl wird separat ergänzt.

## Blattbedeutung

- `--sheets all` übernimmt alle lesbaren Arbeitsblätter, `visible` nur als
  sichtbar belegte. Unbekannte Sichtbarkeit führt bei `visible` zum Fehler;
  Namen, Indizes oder `all` bleiben ausdrücklich wählbar.
- Indizes sind einsbasiert und beziehen sich auf das gesamte Quellverzeichnis.
  Nicht lesbare Diagramm-, Dialog- oder Makroblätter bleiben in der Übersicht.
  Ihre ausdrückliche Auswahl ist ein Fehler; `all` überspringt sie wie bisher.
- Namen sind exakt und unterscheiden Groß-/Kleinschreibung. Wiederholte Namen
  werden dedupliziert. Bei gleichen Namen in der Quelle sind Indizes notwendig.
  `--sheet-name` ist wiederholbar und mit `--sheets` nicht kombinierbar.
- Die Ausgabe folgt immer der Quellreihenfolge. Eine leere Blattauswahl oder ein
  fehlender Name/Index ist ein Fehler, keine stillschweigende Teilübernahme.

## Zellbedeutung und Grenzen

Bis zu 64 wiederholte `--cell-range`-Angaben gelten auf jedem ausgewählten Blatt.
Ein Bereich ist eine A1-Adresse oder ein aufsteigendes geschlossenes Rechteck,
zum Beispiel `B2:D8`. ASCII-Buchstaben dürfen klein geschrieben sein. Ganze
Zeilen/Spalten, `$`-Adressen, Blattpräfixe, offene und rückwärts laufende Bereiche
werden abgewiesen. Die unterstützten Grenzen sind 1.000.000 Zeilen und 16.384
Spalten (`XFD`), entsprechend den Importbudgets.

Überlappungen bilden eine Vereinigung: Jede gewählte Quellzelle wird höchstens
einmal ausgegeben. Die Vereinigung wird an Zeilengrenzen in disjunkte Rechtecke
zerlegt, höchstens 4096 je Blatt. Deshalb können mehrere beschriftete Abschnitte
entstehen. Zwischen entfernten Bereichen werden keine leeren Lücken aufgefüllt.
Bereiche werden an der befüllten Ausdehnung abgeschnitten; vollständig außerhalb
liegende Auswahlen erscheinen ausdrücklich als leer. Leerzellen innerhalb eines
ausgegebenen Rechtecks zählen weiterhin zum gemeinsamen Zellbudget.

Verbundzellen bleiben abgeflacht: Nur ihr gespeicherter Anker trägt den Wert.
Ein Anker außerhalb der Auswahl wird nicht zusätzlich importiert. Formeln
werden nicht ausgewertet und ihre Verweise nicht verfolgt. Gespeicherte
Ergebnisse bleiben maßgeblich, auch bei Verweisen außerhalb der Auswahl;
fehlende Ergebnisse bleiben diagnostiziert. Paket- und Verlustdiagnosen können
sich auf die gesamte geprüfte Arbeitsmappe beziehen.

Die Auswahl begrenzt die Ausgabe. Die vollständige Quelldatei muss weiterhin
alle bestehenden Paket-, XML-, Text- und Parserbudgets bestehen. Eine Auswahl
kann deshalb eine beschädigte oder im Parser übergroße Quelle nicht umgehen.
Quellen werden nicht verändert und bestehende Ausgabeordner nicht überschrieben.

## Library und Bericht

`ConversionOptions.spreadsheetSelection` übernimmt `SpreadsheetSelection` mit
`SpreadsheetSheetSelection` und `[SpreadsheetCellRange]`. `nil` erhält das
bisherige Verhalten. `DocumentConverter.inspectSpreadsheetContents` liefert
`SpreadsheetContentSummary` samt überprüfbarer Quellenidentität; Abbruch und
Prozessfristen entsprechen den anderen Library-Einstiegspunkten.

Quellzuordnungen behalten die ursprüngliche Zelladresse. Bei einer Auswahl
steht zusätzlich `ConversionLocation.sheetIndex` im Ergebnis und Bericht.
Zeilen-/Spaltenversatz wird beim Ausschneiden nicht in neue A1-Koordinaten
umgerechnet. Ein optionaler Bericht speichert auch die typisierte Auswahl.
