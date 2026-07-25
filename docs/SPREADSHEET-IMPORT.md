# Geplanter Tabellenimport

Stand der lokalen Prüfung am 2026-07-25: Pandoc 3.9.0.2 liest XLSX, aber weder
ODS noch XLS. Ein ODS ist dagegen ein dokumentiertes ZIP-Paket; `content.xml`
enthält die Tabellen in stabiler Reihenfolge als `table:table`. Die versionierte
Probe `Tests/PoorMansTextCoreTests/Fixtures/Spreadsheets/multisheet.ods` enthält
zwei Blätter, Unicode, Zahlen, Formeln, einen Zeilenumbruch, ein Pipe-Zeichen und
einen Tabulator. LibreOffice konnte sie verlustfrei nach XLSX zurückschreiben;
Werte, Blattnamen und Reihenfolge blieben erhalten.

Damit ist ein lokaler ODS-Import ohne LibreOffice-Laufzeitabhängigkeit technisch
machbar. Er soll erst nach DOCX, ODT und DOC entstehen und die vorhandene
Paketprüfung für Traversal, Symlinks, Verschlüsselung und Entpackbudgets
wiederverwenden.

## Gemeinsames Workbook-Modell

ODS, XLSX und später XLS sollen nicht jeweils direkt Markdown erzeugen. Ein
formatneutraler Tabellenkern hält mindestens:

- Blattname und Blattreihenfolge;
- Zellposition, typisierten Wert, sichtbaren Text und optionale Formel;
- zusammengeführte Bereiche;
- interne Zeilenumbrüche und leere Zellen;
- Warnungen für nicht darstellbare Diagramme, Bilder, Kommentare und Makros.

Wiederholte ODF-Zeilen und -Spalten werden nur innerhalb fester Zell-, Zeilen-
und Spaltenbudgets expandiert. Bei Überschreitung bricht der Import verständlich
ab; er kürzt keine Inhalte still.

## Zwei Markdown-Darstellungen

Die spätere `ConversionOptions` erhält eine Tabellen-Darstellung:

1. `markdownTable` als Standard: GFM-Tabelle, Pipes maskiert und interne
   Zeilenumbrüche als `<br>`. Die erste vorhandene Zeile bleibt vollständig
   erhalten und bildet die Kopfzeile. Zusammenführungen werden auf den Wert der
   linken oberen Zelle reduziert und gemeldet.
2. `tabSeparated`: ein als `tsv` markierter Codeblock. Zellinterne Tabulatoren
   und Zeilenumbrüche werden reversibel als `\t` und `\n` geschrieben, damit
   Zeilen- und Spaltengrenzen eindeutig bleiben.

Beide Varianten geben angezeigte Zellwerte aus. Formeln werden nicht ausgeführt
und nicht anstelle ihres gespeicherten Ergebnisses angezeigt; fehlende oder
veraltete Ergebniswerte erzeugen eine Warnung.

## Mehrere Blätter

Ein Workbook bleibt eine Markdown-Datei und passt damit zum heutigen
`ConversionResult`:

```markdown
# Arbeitsmappe

## Blatt: Summary

| Product | Units | Price |
|---|---:|---:|
| Äpfel | 12 | 1.50 |

## Blatt: Details & Notes

...
```

Blattnamen werden als Text behandelt, die Reihenfolge bleibt erhalten, und leere
Blätter erhalten eine sichtbare Leermeldung. Ein späterer optionaler Split in
ein Blatt pro Datei wäre eine zusätzliche Veröffentlichungsform und gehört
nicht in den ersten Tabellenadapter.

## Reihenfolge der Umsetzung

1. ODS-Paket erkennen und in das gemeinsame Workbook-Modell lesen.
2. Beide Darstellungen sowie Mehrblatt-, Formel-, Merge- und Budgettests bauen.
3. XLSX in dasselbe Modell einlesen; Pandocs XLSX-Leser dient als unabhängiger
   Output-Vergleich, nicht als Modellgrenze.
4. XLS zuletzt als getrennten OLE-Adapter ergänzen. Der bestehende DOC-Detektor
   weist ein echtes XLS-Fixture bereits als Nicht-Word zurück.
