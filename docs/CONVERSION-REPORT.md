# Quellzuordnung und Konvertierungsbericht

Die Standardkonvertierung schreibt weiterhin nur Markdown und Assets.
`--source-map --json` ergänzt bekannte Quellstellen in der JSON-Antwort.
`--report` schreibt zusätzlich `conversion-report.json` in das fertige Ergebnis;
der Bericht enthält ebenfalls die Zuordnungen. Beide Optionen sind mit
Frontmatter, Textbundle und Stapelläufen kombinierbar. `--stdout` und der
Formatkatalog akzeptieren sie nicht. Ohne JSON oder Bericht hat `--source-map`
keinen auswertbaren Ausgabeweg und wird als Aufruffehler abgelehnt.

Library-Aufrufer wählen `ConversionOptions.sourceMapping` bzw.
`conversionReport`. `ConversionResult` ergänzt optional `sourceIdentity`,
`sourceMappings`, `outputFiles` und `reportFile`. Die vorhandenen Initializer
bleiben durch Standardwerte quellkompatibel. Ein Bericht erzwingt intern die
Zuordnung; `sourceMapping` allein erzeugt keine weitere Datei.

## Versionierter, portabler Bericht

Schema 1 enthält:

- `schemaVersion`, `converterVersion` und erkanntes `format`.
- `source`: Quelldateiname und, soweit belegt, SHA-256 und tatsächlich gelesene
  Bytezahl. Ein fehlender Gesamthash erhält `unavailableReason`.
- `options`: wirksame Konvertierungsoptionen; eine leere OCR-Sprachliste bedeutet
  automatische Sprachwahl. Ein benutzerdefinierter Pandoc-Pfad wird nur als
  `customPandoc` erfasst, ohne seinen absoluten Pfad.
- `diagnostics` und `diagnosticGroups` nach dem [Diagnosevertrag](DIAGNOSTICS.md).
- `outputs`: relative Dateipfade, SHA-256 und Bytezahlen für Markdown, Assets und
  gegebenenfalls `info.json`. Der Bericht selbst ist wegen des Selbstbezugs nicht
  Bestandteil seines Hashmanifests.
- `sourceMappings` und die tatsächlich ausgelassene Zahl `omittedMappingCount`.

Der Quellhash entsteht beim vollständigen Lesen der geprüften Bytes, die dem
Adapter übergeben werden. Ein späteres erneutes Öffnen der ursprünglichen Datei
würde dagegen möglicherweise eine andere Version beschreiben. Unterschiedliche
vollständige Quellstände innerhalb derselben Konvertierung verhindern einen
falschen Bericht und brechen die Veröffentlichung ab.

Ein Verzeichnispaket wie RTFD besitzt keinen einzelnen solchen Byte-Strom.
Sein Gesamthash bleibt ausdrücklich unbekannt. Der Hash eines Masterdokuments
bezeichnet die primäre Datei, nicht automatisch alle zusätzlich referenzierten
Dokumente. Ausgabemanifeste erfassen die tatsächlich erzeugten Assets.
Hashes belegen Byteidentität, keine Inhaltsvollständigkeit und keine Signatur
des Berichts.

Der Bericht enthält standardmäßig keine absoluten Quell-, Ziel-, Werkzeug- oder
Staging-Pfade. Bekannte lokale Pfade in Meldungen werden durch Platzhalter
ersetzt. Aus dem Dokument zitierter Inhalt kann weiterhin private Angaben
enthalten; der Bericht ist kein Werkzeug zur Anonymisierung.

## Bekannte Stellen und UTF-8-Bereiche

PDF-Seiten, Bildframes mit OCR-Ausgabe, Tabellenzellen und Präsentationsfolien
erhalten bekannte Bezüge. CSV/TSV nutzen ihre logischen Zeilen und Felder.
Eine Folienzuordnung umfasst auch ihre gemeinsam ausgegebenen Notizen.
Andere Formate dürfen zunächst keine Zuordnung liefern; `sourceMap.unavailable`
weist darauf hin. Unbekannte Quellstellen werden nicht durch geschätzte
Absatznummern oder erfundene Anker ersetzt.

Jede Zuordnung enthält `source` als `ConversionLocation` und `output` mit
relativem `file`, `utf8Offset` und `utf8Length`. Die Bytezahl beginnt bei null;
das Intervall ist `[offset, offset + length)`. Es bezeichnet den tatsächlich
geschriebenen Markdown-Quelltext, einschließlich notwendiger Maskierungen,
Linksyntax oder Seiten-/Folienüberschriften. Ein leerer Zelltext kann einen
Bereich der Länge null haben. Die Werte sind keine UTF-16-Positionen und keine
Bildschirmkoordinaten.

Frontmatter verschiebt alle Bereiche um seine tatsächliche UTF-8-Länge.
Textbundle-Umschreibungen passen die Bereiche anhand der tatsächlich geänderten
Linkziele an; Codecontainer bleiben geschützt. Nicht sicher abbildbare
Teilüberschneidungen werden gezählt und ausgelassen. Im fertigen Staging werden
Bereichsgrenzen und UTF-8-Gültigkeit geprüft. Der Markdown-Inhalt enthält keine
technischen Marker für diese Zuordnung.

Vor späterer Verwendung müssen die Ausgabebytes mit dem zugehörigen Manifest
übereinstimmen. `ConversionOutputFile.matches` prüft das; `ConversionTextRange.text`
liefert nur gültige UTF-8-Ausschnitte. Ein Sprung in eine inzwischen veränderte
Quelle braucht ebenfalls einen passenden Quellhash; `matchesFile` liefert bei
unbekannter Identität `false`. Externe Leser müssen Schema 1 erkennen und relative
Pfade sicher auflösen; ein fremder Bericht ist nicht automatisch vertrauenswürdig.

## Grenzen und atomare Veröffentlichung

Eine explizite PDF-Auswahl steht als kanonische Bereichszeichenfolge unter
`options.pdfPages`, etwa `"2,4-6"`. Ohne Auswahl fehlt dieses optionale Feld;
Schema 1 bleibt rückwärts lesbar. Seitenbezüge nennen die physischen Nummern
der vollständigen Quelle, auch wenn nur ein Teil importiert wurde.

Ein Auftrag sammelt höchstens 100.000 Zuordnungen. Für die zusätzliche Grenze
von 8 MiB zählen UTF-8-Bytes der Quellkennungen plus 64 Byte je Eintrag.
Weitere Stellen werden mit `sourceMap.limited` und genauer Anzahl gemeldet;
die Dokumentausgabe wird nicht gekürzt. Diagnosemeldungen im Bericht haben
begrenzte Textfelder. Überlange Identifikatoren werden unbekannt gelassen,
statt durch einen abgeschnittenen Namen eine falsche Fundstelle zu behaupten.
`report.detailsLimited` nennt die betroffenen Felder. Die ursprünglichen
Library-/CLI-Diagnosen bleiben erhalten. Der kodierte Bericht ist auf 64 MiB
begrenzt.

Bericht, Hashmanifest und Zuordnungen entstehen nach Frontmatter und
Textbundle-Umbau vollständig im privaten Staging. Der Bericht wird dort exklusiv
angelegt. Erst danach wird das gesamte Ergebnis atomar veröffentlicht.
Abbruch, Kollision, Schreibfehler und widersprüchliche Quellstände hinterlassen
keinen halben Bericht am Ziel; vorhandene Ausgaben werden nicht überschrieben.

## Ausgewählte Tabellenbereiche

`options.spreadsheetSelection` ist optional; ohne Auswahl fehlt das Feld wie bisher. Ausgewählte Tabellenzellen behalten ihre ursprüngliche A1-Adresse und zusätzlich den einsbasierten `source.sheetIndex` aus dem gesamten Blattverzeichnis. Damit sind auch gleiche Quellblattnamen unterscheidbar. Überlappende Bereiche erzeugen keine doppelten Zuordnungen. Verlustdiagnosen dürfen die gesamte geprüfte Arbeitsmappe betreffen; die Auswahl entfernt keine Paketwarnungen.

## Ausgewählte Präsentationsinhalte

`options.presentationSelection` ist optional. Bei einer ausdrücklichen Auswahl enthält es `slides` als normalisiertes Intervall und `includeNotes`. `nil` bei den Folien bedeutet alle Folien. `source.slide` bleibt die ursprüngliche Position in der Präsentation, auch wenn Folien übersprungen werden. Absichtlich ausgeschlossene Folien/Notizen erzeugen keine Inhaltsverlustdiagnosen.
