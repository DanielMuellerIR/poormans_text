# Nativer Tabellenimport

Poor Man's Text liest ODS, XLSX und binäres XLS ohne LibreOffice, Excel oder
Pandoc. Die formatspezifischen Leser enden in demselben Arbeitsmappenmodell;
erst danach entsteht Markdown. Dadurch gelten für alle drei Formate dieselbe
Blattreihenfolge, Darstellung, Größenbegrenzung und Warnungssemantik.

## Leser und Sicherheitsgrenzen

- ODS wird als geprüftes OpenDocument-ZIP-Paket gelesen. `content.xml` liefert
  Blätter, typisierte Werte, sichtbaren Text, Formeln, Wiederholungen und
  Zellverbünde sowie über einen deklarierten XLink-Namensraum verknüpfte Zellen.
- XLSX wird als geprüftes OOXML-ZIP-Paket gelesen. Arbeitsmappenbeziehungen
  dürfen nur auf interne Arbeitsblätter zeigen; entfernte Beziehungen und
  ausbrechende Pfade werden abgelehnt. Externe Hyperlink-Beziehungen eines
  Arbeitsblatts dienen nur als Linkziel und werden nie geöffnet. Gemeinsame und
  inline gespeicherte Texte, Zahlen, Wahrheitswerte, Formeln und
  zwischengespeicherte Ergebnisse werden übernommen.
- XLS wird als OLE-Compound-File mit BIFF8-Arbeitsmappe gelesen. FAT-, DIFAT-,
  Verzeichnis- und Mini-Stream-Ketten werden begrenzt und auf Schleifen geprüft.
  URL-, Datei- und Blattziele aus HLINK-Records werden als Linkziele übernommen;
  als Altformat erhält XLS immer eine eigene Verlustwarnung.

Ein Import darf höchstens 256 Blätter, 100.000 Zeilen pro Blatt, 16.384 Spalten
und insgesamt 1.000.000 expandierte Zellen enthalten. Dasselbe Limit gilt für
die Tabelle gemeinsamer XLSX-Texte. Überschreitungen brechen mit einer
verständlichen Fehlermeldung ab; Inhalte werden nicht still gekürzt.

## Gemeinsames Arbeitsmappenmodell

Das interne Modell hält Blattname und -reihenfolge sowie pro Zelle den
typisierten Wert, den gespeicherten Text, eine optionale Formel und ein Linkziel.
Leere Zellen, interne Zeilenumbrüche und wiederholte ODF-Zeilen oder -Spalten
bleiben erhalten.

Formeln werden nie ausgeführt. Vorhandene gespeicherte Ergebnisse werden
ausgegeben; fehlt ein Ergebnis, erscheint eine Warnung. Zellverbünde werden auf
den Wert der linken oberen Zelle reduziert und ebenfalls gemeldet. Diagramme,
Zeichnungen, Kommentare, Makros und andere nicht darstellbare Objekte führen zu
einer Verlustwarnung.

Eine Zelle kann ein Linkziel tragen. Bei einer sonst leeren XLSX-Zelle wird dafür
auch das `display`-Attribut des Hyperlinks als sichtbarer Text verwendet. Mehrere
unterschiedliche Linkziele in einer Zelle passen nicht in dieses Modell: Der
erste Zielwert und der Text bleiben erhalten, der weitere Zielwechsel führt zu
`spreadsheet.unsupportedObjects`. Ein Diagramm- oder Dialogblatt hat
kein Zellgitter: Es wird übersprungen und löst dieselbe Warnung aus, statt die
ganze Arbeitsmappe abzulehnen.

## Zwei Markdown-Darstellungen

Standard ist `markdownTable`: Jedes Blatt wird zu einer GFM-Tabelle. Die erste
vorhandene Zeile bleibt vollständig erhalten und bildet die Kopfzeile. Pipes und
Backslashes werden maskiert, interne Zeilenumbrüche als `<br>` geschrieben.
Verlinkte Zellen werden als Markdown-Link gerendert; Linktext und Ziel werden
dabei so maskiert, dass sie keine weitere Tabellenspalte oder Linksyntax bilden.

Als Linkziel kommen nur `http`, `https`, `mailto` und `file` sowie Ziele ganz
ohne Schema durch — also relative Pfade neben der Arbeitsmappe und blattinterne
`#`-Ziele. Ein ausführbares Schema wie `javascript:` oder ein eingebettetes
`data:` wird verworfen: Poor Man's Text öffnet ein Ziel zwar nie selbst, aber im
Markdown-Viewer des Nutzers stünde sonst ein klickbarer Link aus einer fremden
Tabelle. Der sichtbare Zelltext bleibt in diesem Fall erhalten, und der Verlust
des Ziels wird als `spreadsheet.unsupportedObjects` gemeldet.

Ein einzelner Buchstabe vor dem Doppelpunkt gilt dabei als
Windows-Laufwerksbuchstabe und nicht als Schema: `C:\Berichte\2026.xlsx` aus
einem XLS-Dateimoniker bleibt als Ziel erhalten.

Mit `--spreadsheet-format tsv` wählt das CLI `tabSeparated`: Jedes Blatt wird zu
einem `tsv`-Codeblock. Zellinterne Backslashes, Tabulatoren und Zeilenumbrüche
werden als `\\`, `\t` und `\n` geschrieben, sodass Zeilen- und Spaltengrenzen
eindeutig bleiben. Ein Codeblock kann keinen anklickbaren Link enthalten; für
eine verlinkte Zelle enthält er deshalb deren maskierten Markdown-Quelltext.

## Mehrere Blätter

Eine Arbeitsmappe bleibt eine Markdown-Datei:

```markdown
# Arbeitsmappe

## Sheet: Summary

| Product | Units | Price |
| --- | --- | --- |
| Äpfel | 12 | 1.50 |

## Sheet: Details & Notes

...
```

Blattnamen werden als Text behandelt, die Quellreihenfolge bleibt erhalten, und
leere Blätter erhalten die sichtbare Meldung `_Empty sheet._`. Eine Ausgabe in
eine Datei pro Blatt ist derzeit bewusst nicht Teil des Ergebnisvertrags.

## Verifikation

Die Tests verwenden eine echte mehrblättrige ODS-Datei und ein echtes binäres
XLS aus unabhängigen Erzeugern sowie selbst gebaute XLSX-Pakete. Sie vergleichen
die XLS-Inhalte mit der unabhängigen ODS-Arbeitsmappe und den nativen XLSX-Inhalt
zusätzlich direkt mit Pandoc. Blattreihenfolge, Unicode, Formeln, Zellverbünde,
interne Umbrüche, Pipes, Tabulatoren, Linkziele, Budgets, Warnungen und
unveränderte Quelldateien sind abgedeckt.
