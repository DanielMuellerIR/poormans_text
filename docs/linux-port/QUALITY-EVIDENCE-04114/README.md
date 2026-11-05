# Automatische begrenzte Konvertierungsqualität 0.41.14

Prüfdatum 2026-11-05. ProduktCLI SHA256
`8abc9197eeced8df043d788e349acb553bd86dd81546a6fda1faf15a93bac0cb`.
SDK-freies vorhandenes Image `pmt-linux-gui-test:latest`, Image-ID
`sha256:e62668d624b35698964d0e0146fb4e563cbe68758973ea4a424f9a538cd37949`.
Kein Netz, kein HostGUI, keine Installation, keine Produktquellenänderung.

`final/summary.json` ist der tatsächlich ausgeführte konsolidierte Lauf: Exit 1,
weil natürliche Text-/Tabellenqualität unvollständig bleibt. Die zehn synthetischen
Hauptfamilien DOCX/ODT/EPUB/CSV/XLSX/RTF/RTFD/MBOX/ENEX/PPTX bestehen; zusätzlich
bestehen die vorhandenen 15 Raster-/OCR- und 13 PDF-Szenarien. Die 13 PDF-Szenarien
schließen erwartete Ablehnungen ein; sie sind nicht 13 erfolgreiche Konvertierungen.
Strukturierte OCR ist unavailable, ihr Qualitätsnachweis bleibt SKIP; korrekte
Ablehnung wird geprüft. Keine vollständige Formatmatrix oder visuelle Abnahme.

`quality.py` erzeugt temporäre Dokumente aus unabhängigen Text-/Zellvorgaben,
prüft Reihenfolge, exakte CSV-/XLSX-Zellreihen, Original-PNG-Bytes, Quellbytes,
Outputhashes und erwartete Diagnosen. Die Gegenprobe entfernt den ersten Solltext
und muss am selben Inventarprüfer scheitern. Die normalen Familien sind keine
breite Naturkorpusabnahme; sie enthalten keine komplexen Formatvarianten.

## Reproduktion

Die beiden Prüfer stehen inzwischen unter `scripts/linux-probes/quality/`. Nebeneinander ablegen. Einen
neuen Ergebnisordner verwenden. Beispiel aus dem Repo, bei vorhandener Runtime:

```sh
work=$(mktemp -d /tmp/pmt-quality-repeat.XXXXXX)
cp /pfad/zur/Lieferung/quality.py /pfad/zur/Lieferung/run_quality.py "$work/"
docker run --rm --network none --user "$(id -u):$(id -g)" \
 --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
 -v "$PWD:/repo:ro" -v "$work:/work" \
 -e LD_LIBRARY_PATH=/repo/.build/linux-runtime/lib -e HOME=/work -e TMPDIR=/work \
 pmt-linux-gui-test:latest python3 /work/run_quality.py \
 --repo /repo --cli /repo/.build/linux-runtime/bin/poormans-text --root /work/result --expected-cli-sha256 8abc9197eeced8df043d788e349acb553bd86dd81546a6fda1faf15a93bac0cb
```

Der erwartete Exit für den hier untersuchten unveränderten Produktstand ist 1.
Die CLI-Identität wird vor Ausführung geprüft; ein anderes Artefakt muss ausdrücklich
mit `--expected-cli-sha256` gewählt werden. Das Image enthält kein Swift-SDK.
Der fixierte lizenzierte Naturkorpus kommt aus dem Repo unter
`docs/linux-port/P11-NATURAL-EVIDENCE/inputs`; Manifest, Referenz und Attribution
bleiben dort maßgeblich. Fehlende Inputs führen zu explizitem SKIP, nie Download.
Die vorhandenen Produktproben brauchen Pandoc, Pillow, Poppler-GI/Cairo, qpdf,
Tesseract und vorhandene eng/deu/osd-Sprachdaten. Keine Abhängigkeit wird installiert.

## Natürliche Verluste

`final/natural/evidence.json` trennt Integrität von Qualität. Alle sechs
Konvertierungen haben unveränderte Quellen und korrekte Ausgabemanifeste.
Wortinventar: Seite 132 digital/OCR je319 von339,20 fehlen/1 extra;134 digital
152 von237,85 fehlen;134 OCR203 von237,34 fehlen/29 extra;135 beide561 von561,
ein zusätzlicher Fußnotenmarker `1`. Kein Verlustschwellwert wird aufgeweicht.
Alle9 Zelltexte von132 stehen als Prosa in Quellreihenfolge, jedoch fehlen
Tabellenstruktur und colspan. Gefundene Textanker bleiben in GT-Reihenfolge;
das beweist keine Reihenfolge nicht gefundener Elemente.

`natural-diagnosis.json` vergleicht zusätzlich gegen rohe Poppler-Textschicht:
Die digitalen Fließtexte sind vollständig gegenüber dieser Schicht; auf132 fehlt
die Beschriftung der eingebetteten Störzeichnung bereits dort. Ein weiterer
Inventarunterschied ist GT `Rio` gegenüber digitalem Original `Río`; diese
Schreibvariante wird transparent erhalten, nicht als Produktkorrektur behandelt.
Auf134 fehlen digitale Charttitel/Achsen/Zahlen bereits in Popplers Textschicht.
OCR ergänzt Chartinhalt, lässt jedoch Werte aus und fügt Falscherkennungen hinzu.
Je zwei Originalgrafiken von132/134 bleiben in beiden Produktmodi mit gleichen
Ausgabehashes erhalten; vollständiger Textverlust als durchsuchbarer Markdowntext
ist deshalb von Verlust der Bilddarstellung zu unterscheiden.

Diagnosen: `pdf.layoutNotPreserved`, `pdf.vectorGraphicsNotExtracted`,
`pdf.linuxLayoutApproximation`, bei132/134 `pdf.imagesRasterized`; OCR zusätzlich
`pdf.ocrConflict`/`pdf.ocrApplied`, bei134 auch `pdf.layoutAmbiguous`;
134 meldet `pdf.linkTargetUnavailable`. Es gibt keine spezifische vollständige
Bildtext-/Zellverlustdiagnose. Ein sicherer möglicher Anschluss wäre eine getrennte,
verlustbewusste OCR von Bildregionen mit eindeutiger Quellzuordnung und Prüfung
gegen Doppelübernahme. Das vorhandene strukturierte P11-Projekt bleibt ein eigener
nicht integrierter Ansatz; daraus wird hier kein einfacher Produktfix behauptet.

## Begrenzter DPIversuch

`dpi_quality.py`/`dpi-run/summary.json` messen ausschließlich rohe Poppler-/Tesseract-
OCR, getrennt vom Produktmerge. Reale Poppler/Cairo-Raster144 vs300dpi,16MP je
Seite, dieselben installierten Sprachen/psm1 je Paar, keine GT-abhängige Korrektur.
Originale TSV und erkannte Texte bleiben als kleine Nachweise erhalten.

| Quelle | Treffer144→300dpi | Fehlende144→300 | Zusätzliche144→300 |
|---|---:|---:|---:|
| Natur132,339 Solltokens |316→321|23→18|2→47|
| Natur134,237 Solltokens |201→228|36→9|30→7|
| Natur135,561 Solltokens |560→560|1→1|0→0|
| Bestehendes mixed.pdf,46 Solltokens |45→45|1→1|1→1|

300dpi verbessert134 deutlich, verschlechtert aber auf132 die Präzision durch
zusätzliches Bildrauschen. Kein allgemeines Qualitätsgrün. Natürliche Seiten:
1.658.880→7.200.000 Pixel; im unveränderten64MP-Gesamtbudget passen38→8 solcher
Seiten. Das vorhandene synthetische mixed.pdf hat eine große1600×1200pt-Seite:
7.680.000→15.996.752 Pixel;300dpi werden auf207.846dpi gekappt, Budget8→4 Seiten.
DPIänderung allein löst weder Tabellenstruktur noch den sicheren OCR-Merge.

Reproduktion nach erzeugtem PDFfixture:
`python3 dpi_quality.py --repo REPO --synthetic RESULT/pdf/fixtures/mixed.pdf --root NEUES_DPI_ZIEL`
im selben Image mit GI/Cairo/Tesseract. Quellen bleiben gleich; gerenderte PNGs
werden nach TSV-/Hash-Erfassung entfernt. Die DPIprobe ist kein Produktpatch.

## Aufbewahrung

Keine kopierte Runtime oder SDK. Alle Testcontainer liefen mit `--rm`; temporäre
Familienfixtures werden vom Prüfer entfernt. Der konsolidierte Lauf entfernt große
regenerierbare Ausgabebilder nach abgeschlossener Hashprüfung. Der frühe offene
Naturfehlerbeleg enthält Bildausgaben zur aktuellen Fehleranalyse; diese nach
Übernahme durch den Writer entfernen. Kleine Skripte, an die GT gebundene Text-/JSON-/TSV-
Belege für den offenen Fall beim nächsten Konvertermeilenstein erneut prüfen.
