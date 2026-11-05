# Begrenzter Release-Nachweis auf drei natürlichen PDFs

2026-11-05. Release 0.41.9, ausgeführter ELF-SHA256
`b8b4c0481b03b7006afe592a97bc664920a2b65087a75767ddcd5aedc5502a55`.
Der Hash wurde in jedem der sechs tatsächlichen CLI-Prozesse über `/proc/PID/exe`
erfasst. Rohbeleg: [release-b8b4c048.json](release-b8b4c048.json).

Alle sechs Fälle endeten mit Exit 0, je 1.091–3.442 s, zusammen 14.467 s. Beide Modi
wurden auf jedem Dokument geprüft: OCR off und always/standard/en. Alle Quellen
blieben unverändert. Alle sechs Reports stimmen bei Quell-SHA256/Bytezahl; alle 14
Ausgabedateien einschließlich 8 PNG-Assets stimmen bei Report-SHA256/Bytezahl.
Das belegt Integrität dieses Durchlaufs, keine allgemeine Performance oder
Pixelgleichheit aller PDF-Inhalte.

| Seite/Dateiende | Modus | GT-Token | Multiset-Matches | Fehlende GT-Token | Zusätzliche Ausgabetoken |
| --- | --- | ---: | ---: | ---: | ---: |
|132|off|339|319|20|1|
|132|always/en|339|319|20|1|
|134|off|237|152|85|0|
|134|always/en|237|197|40|34|
|135|off|561|561|0|1|
|135|always/en|561|561|0|1|

Die feste Tokenregel und ihre Grenzen stehen in [CORPUS.md](CORPUS.md).
Die Texte in den GT-Grafiken gehören ausdrücklich zum erwarteten Wortbestand.
Rio/Río auf Seite 132 und der zusätzliche Original-Fußnotenmarker 1 auf Seite 135 bleiben als
bekannte Abweichungen sichtbar. Die Multiset-Zahlen belegen keine positionsgenaue
Erkennungsquote. Diagramm-OCR auf Seite 134 verbessert die Textabdeckung gegenüber off,
behält aber 40 fehlende/34 zusätzliche Tokens und 10 Unsicherheits-Payloads.

## Wortgrenzen verbessert, Tabellenstruktur weiterhin nicht erhalten

Auf Seite 132 besitzen im begrenzten Tabellenbereich nun **9/9 Zelltexte abgegrenzte
Tokenfolgen**. Der frühere Stand 4bf60152 hatte dort 5/9; die zwei Verklebungen
`SplitfinAmeca` und `SkiffiaSkiffia` sind im neuen Ergebnis getrennt.
[Vorher-Beleg](baseline-4bf60152.json) und Nachher wurden separat ausgeführt;
keine früheren Resultate als neue Tests ausgegeben.

Die erste Datenzeile bleibt vertauscht: `Cyprinodon alvarezi` steht vor
`Potosi Pupfish`. **Keine Tabelle, keine Zellzuordnung und kein colspan werden
rekonstruiert.** Die Reihenfolge der gefundenen Zelltexte ist weiterhin falsch.
Der Produktpfad benennt diese Grenze mit `pdf.linuxLayoutApproximation`.

Die jeweils gefundenen ersten bis zu 8 Wörter der GT-Elemente bleiben in ihrer
GT-Ankerreihenfolge. Das ist kein vollständiger Absatz-/Lesereihenfolgenachweis:
Auf Seite 132 unterbricht z.B. Bildunterschrift 6.3 weiterhin einen laufenden Absatz vor
dessen Schlusswort `experience`. Bild-/Diagrammtextanker können fehlen;135 enthält
einen zusätzlichen Fußnotenmarker. Einzelbefunde stehen im JSON, ohne sie durch
Normalisierung in einen vermeintlich vollständigen Erfolg umzudeuten.

Kein Crash in diesen sechs Fällen. Keine P11-Abnahme, Mac-Parität oder allgemeine
OCR-/Tabellenqualitätszusage. Quelle, Attributionen und fehlende Span-/Scanfälle
bleiben in [CORPUS.md](CORPUS.md) und [ATTRIBUTION.md](ATTRIBUTION.md) beschrieben.
