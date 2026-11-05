# Natürlicher P11-Startkorpus

Drei natürliche einseitige PDFs aus dem offiziellen **Upstage DP-Bench**, feste
Revision `24702c61a2fb13325534be664653bc6e60250d13`. Die Auswahl stammt aus Donald J.
Orths *Fish, Fishing, and Conservation* (2023), nicht aus eigens erzeugten PMT-
Testseiten. Sie dient zur begrenzten Qualitätsmessung, nicht als vollständige
Abnahme strukturierter Dokumenterkennung.

| Datei | Originalseite | Bytes | Inhalt und Original-Ground-Truth |
| --- | ---: | ---: | --- |
|01030000000132.pdf|132|373820|10 Elemente; Tabelle mit fünf Zeilen/neun Zellen, ein colspan=2; Text und Bilder.|
|01030000000134.pdf|171|631921|6 Elemente; Fließtext, zwei Diagramme mit Text und Bildunterschriften.|
|01030000000135.pdf|191|29037|6 Elemente; Fließtext, Fußnote und Seitenfuß.|

Die drei PDFs umfassen zusammen 1034778 Bytes. `manifest.json` enthält ausschließlich
revisionsfeste Primär-URLs, Größen und SHA256. `selected-reference.json` enthält die
über Dateinamen eindeutig zugeordneten drei Originalrecords, ohne Textkorrekturen.
Quelle der vollständigen Referenz ist ebenfalls mit Größe und SHA256 dokumentiert.
Die Elementfolge des Arrays ist die annotierte Lesereihenfolge; sie wird nicht aus
Boxkoordinaten erraten. Tabellen-HTML enthält Zelltexte und explizite Spannen.

## Explizite Reproduktion

Python 3.9+ und die gebaute CLI genügen für die Skripte. Der eigentliche Produktlauf
benötigt seine dokumentierten lokalen PDF-/OCR-Werkzeuge. Keine Dataset-SDKs,
Modelle oder automatische Installation. Der folgende **ausdrückliche optionale
Fixture-Download** lädt nur die drei PDFs; er ist keine Produktfunktion:

```sh
work=$(mktemp -d)
python3 scripts/linux-probes/p11/download_natural.py "$work/corpus"
python3 scripts/linux-probes/p11/natural_benchmark.py \
  --cli ./poormans-text --corpus "$work/corpus" --root "$work/results"
```

Downloader und Benchmark verlangen jeweils einen noch nicht vorhandenen Zielordner.
Sie überschreiben keine bestehenden Ergebnisse. Der Downloader prüft feste Namen,
HTTPS-URLs, Bytezahlen und SHA256; Gesamtumfang bleibt unter 10 MB. Der Benchmark
prüft Korpus-/Annotationsidentität vor dem ersten Prozessstart und erzeugt sechs
Fälle: jede Seite mit OCR off und always/standard/en, je maximal 120 Sekunden.
Die normale Produktkonvertierung lädt nichts aus dem Netz.

`evidence.json` enthält relative Quelldateinamen, Exitstatus/Laufzeiten, Quell- und
Ausgabehashprüfungen, Assetanzahl, Diagnosen, Fehl-/Zusatzwörter, Elementanker und
Tabellenzellvergleich. Auf Linux wird der tatsächlich laufende ELF-Prozess über
/proc beobachtet und gehasht; andernfalls bleibt dieser Hash ausdrücklich unbekannt.
Rohstdout/-stderr und Produktresultate verbleiben im temporären Ergebnisordner;
sie enthalten absolute Aufrufpfade und sind nicht als öffentliche Belege vorgesehen.

## Grenzen der Auswertung

Wortinventar: Unicode-`\w+` und casefold; keine Akzententfernung, Dehyphenation,
Wortgrenzenreparatur oder GT-Korrektur. Erzeugte Markdown-Titel, Seitenanker,
Bildlink-Alttexte und Links-/Annotationsanhänge sind ausgeschlossen. Bei erzeugten
OCR-Unsicherheitsklammern wird nur das Etikett entfernt, der unsichere Text bleibt.
NFKC wird zusätzlich separat protokolliert und ersetzt den Primärvergleich nicht.
Ein Multiset misst keinen positionsgenauen Volltext; Elementanker sind ebenfalls
kein vollständiger Nachweis zusammenhängender Absätze oder korrekter Zellreihenfolge.

Der Zellvergleich ist auf den Tabellenbereich vor der unabhängig gefundenen
Tabellenunterschrift beschränkt. Spätere Wiederholungen in Fließtext/Bildunterschrift
können eine fehlende Zelle nicht kompensieren. Vollständige Zellzeichenfolgen als
Substrings belegen weder Wortgrenzen noch Tabellenstruktur/colspan.

Bekannte GT-Abweichungen: In132 steht `Rio`, im Original `Río`; auf Seite 135 repräsentiert
GT einen Fußnotenmarker `1` nicht vollständig. Keine stille Korrektur. Grafiktexte
in der Referenz sind nicht vollständig im digitalen PDF-Textlayer enthalten;
fehlende Wörter bei OCR off sind deshalb getrennt von Verlusten digitalen Texts
zu interpretieren. Die Auswahl enthält keine vertikalen Spannen, leeren Tabellen-
zellen oder natürlichen Scans und nur eine Tabelle/einen Buchtitel. Keine Mac-
Parität, strukturelle Gleichwertigkeit oder allgemeine OCR-Güte daraus ableiten.

## Primärquellen und Rechte

Siehe [ATTRIBUTION.md](ATTRIBUTION.md). Original-PDFs gehören nicht in das Repository.
Die kleinen Originalannotationrecords, Manifest und neutralen Belege genügen dort;
PDFs können bei Bedarf ausdrücklich neu heruntergeladen und verifiziert werden.
