# Speicher und Laufzeit der Paketverarbeitung

## ZIP-Erkennung: Messung 2026-09-30

`scripts/benchmark_zip_detection.py` baut zwei optimierte reine Kernprobes:
Git-Basis `270e1b9` und aktuellen Quellstand. Unveränderliche Quellkopien und
SHA-256-Manifeste ordnen beide Messprobes ihren Quellen zu. Keine App wird gestartet.

Die drei gültigen temporären ODT-Pakete enthalten denselben `mimetype`, dieselbe
Dokument-XML und einen unkomprimierten Zusatzeintrag aus Nullbytes. Die Nutzlast
wird als Sparse-Datei erzeugt; ihre CRC ist korrekt und Info-ZIP prüfte den
größten Fall erfolgreich vollständig. Gemessen wird ausschließlich die
Erkennung mit Namensindex und Lesen der beiden Metadateneinträge. Die vollständige
Prüfung aller Medien vor der Konvertierung bleibt erhalten und ist nicht Teil
dieser Messung. Metadaten und Namenslisten sind vor/nachher bytegleich; alle
Quellenhashes bleiben unverändert.

Umgebung: Apple M5, arm64, macOS 26.6.2, Swift 6.4. Drei abwechselnde Läufe je
Probe und Eingabe, ohne parallel laufende Projektbuilds oder Tests. Zeit ist
der Median innerhalb des Erkennungsprobes, Speicher der größte Prozess-RSS
(`maximum resident set size` von `/usr/bin/time -l`).

| Zusätzliche Nutzlast | Erkennung vorher | Erkennung nachher | Spitzen-RSS vorher | Spitzen-RSS nachher |
| --- | ---: | ---: | ---: | ---: |
| 1MiB | 0.676 ms | 0.782 ms | 10.47 MiB | 9.56 MiB |
| 256MiB | 18.859 ms | 0.803 ms | 265.47 MiB | 9.56 MiB |
| 768MiB | 52.158 ms | 0.744 ms | 777.47 MiB | 9.56 MiB |

Beim 768-MiB-Fall fällt der Spitzen-RSS um 98,77 %. Die Mediengröße erhöht den
Erkennungsspeicher in dieser Matrix nicht mehr. Das kleine Paket zeigt einen
zusätzlichen Prüfaufwand von etwa 0,106 ms; ein allgemeiner Laufzeitgewinn ist
nicht zugesagt. Die Gesamtprozesszeiten einschließlich Start lagen im Median
bei 9,34/8,84 ms, 28,77/9,84 ms und 64,57/8,46 ms (vorher/nachher).

Der Reader hält einen 64-KiB-Lesepuffer, den höchstens 65.557 Byte langen
Schlussbereich, den Namensindex und angeforderte, jeweils bereits auf 16 MiB
begrenzte Metadaten. Der Index wächst weiterhin mit Zahl und Länge der Namen;
dies ist keine Zusage eines konstanten Gesamtspeichers für beliebige Verzeichnisse.
Sparse-Nullnutzlast und diese isolierte Erkennung erlauben keine allgemeine
Aussage über kalte Datenträger oder den RSS einer vollständigen Konvertierung.

Wiederholen, mit einem neuen temporären Ordner:

```sh
python3 scripts/benchmark_zip_detection.py --baseline 270e1b9 --root /tmp/zip-detection-new-run
```

`benchmark.json` enthält Einzelwerte, Quellenmanifeste und Datei-/Ergebnishashes.
Der Ablauf schreibt weder in den Git-Index noch in vorhandene Ausgabeordner.

## Paketverarbeitung: Messung 2026-09-05

`scripts/benchmark_packages.py` erzeugt drei lokale Testfälle und prüft bei jedem
Lauf sämtliche eindeutigen Textmarken, Bilddateien und Quellenhashes. Die Messung
verwendet die Release-CLI, drei getrennte Ausgaben pro Fall und `/usr/bin/time -l`.
Es liefen keine Projektbuilds oder Tests gleichzeitig. Die Zahlen sind einzelne
Messserien auf einem Rechner, keine allgemeine Geschwindigkeitszusage.

Umgebung: Apple M5, arm64, macOS 26.6.2, Swift 6.3.3, Pandoc 3.9.0.2.
Die XLSX-Datei enthält 32 Blätter mit je 3.000 Zeilen und vier eindeutigen
Textzellen (384.000 Zellen). Die DOCX-Datei wurde von Pandoc erzeugt und enthält
64 unterschiedliche PNG-Bilder mit insgesamt etwa 50 MB. Der dritte Fall sind
200 kleine CSV-Dateien. PNG-Pixel werden mit festem Zufallsstartwert erzeugt.

### Vergleich unmittelbar vor und nach der Paketänderung

Basis ist `503904c`, also **nach** der Fortschritts-/Abbruchimplementierung.
Beide CLIs wurden separat aus ihrem Quellstand als Release gebaut und auf
identischen Eingabedateien ausgeführt. Zeit bedeutet Median der drei Läufe,
Speicher den höchsten gemeldeten Wert `maximum resident set size` aus diesen
Läufen, in Bytes. Dieser Wert ist keine Summe gleichzeitig belegter Ressourcen
aller Prozesse; insbesondere lässt sich daraus kein Batch-Parallelitätsbudget
ableiten.

| Eingaben | Zeit vorher | Zeit nachher | Speicher vorher | Speicher nachher |
| --- | ---: | ---: | ---: | ---: |
| XLSX, 384.000 Zellen | 3,46 s | 3,41 s | 129.744.896 | 87.621.632 |
| DOCX, 64 Bilder | 0,36 s | 0,33 s | 166.281.216 | 166.281.216 |
| 200 CSV-Dateien | 0,21 s | 0,28 s | 17.825.792 | 17.350.656 |

Der größte XLSX-Speicherwert fällt um 32,47 %. Alle neun Ausgabesätze haben exakt
dieselben Datei-Hashes wie die Vergleichsausgaben, einschließlich der Markdown-
Dateien und Bild-Assets. Jede XLSX-Textmarke kommt genau einmal vor; bei DOCX
stimmen alle 64 Bildhashes mit den Original-PNGs überein. Alle Quellenhashes sind
unverändert.

Ein allgemeiner Laufzeitgewinn ist nicht belegt. Bei den kurzen CSV-Läufen
schwankten die Einzelwerte über die Messserien zwischen 0,20 und 0,30 s; die
letzte Vergleichsserie ist langsamer. Für medienreiche DOCX-Dateien zeigt diese
Messung keinen Speichervorteil. Das XLSX-Zellmodell bleibt vollständig im
Speicher; eingespart werden die gleichzeitig gehaltenen Blatt-XML-Dateien und
wiederholte Paketlesevorgänge.

Eine erste Variante kopierte und prüfte alle ZIP-Einträge auch bei jedem
Erkennungsversuch vollständig. Sie benötigte bei DOCX im Median 0,38 s und wurde
verworfen. Die Erkennung verwendet weiterhin einen nichtgemappten Deskriptor-
Snapshot mit Archiv- und gelesenen Eintragsprüfungen. Der Konvertierungsweg prüft
seine selbst erzeugte Arbeitskopie weiterhin vollständig, einschließlich CRC
und Größen aller Medien.

### Frühere Gesamtbaseline

`ad476f4` liegt vor der Fortschritts-/Abbrucharbeit und ist deshalb kein isolierter
Vergleich für die Paketänderung. Sie bleibt zur Einordnung dokumentiert:

| Eingaben | Zeit | Speicher |
| --- | ---: | ---: |
| XLSX, 384.000 Zellen | 3,33 s | 130.383.872 |
| DOCX, 64 Bilder | 0,28 s | 166.281.216 |
| 200 CSV-Dateien | 0,23 s | 17.661.952 |

Auch mit dieser Gesamtbaseline stimmen sämtliche Ausgabedatei-Hashes überein.

### Wiederholen

```sh
swift build -c release --product poormans-text
python3 scripts/benchmark_packages.py generate "$TMPDIR/pmt-benchmark-new"
python3 scripts/benchmark_packages.py measure "$TMPDIR/pmt-benchmark-new" \
  .build/release/poormans-text before
# Nach der zu messenden Änderung neu bauen, dieselben Quellen wiederverwenden:
python3 scripts/benchmark_packages.py measure "$TMPDIR/pmt-benchmark-new" \
  .build/release/poormans-text after \
  --compare "$TMPDIR/pmt-benchmark-new/before.json"
```

`generate` benötigt Pandoc im `PATH` oder `--pandoc PATH`. Ein vorhandenes
Eingabeverzeichnis oder Manifest wird nicht überschrieben. `measure` verlangt
neue Ausgabenamen und schreibt pro Lauf die Rohmessung sowie eine JSON-Datei mit
Zeiten, Speicherwerten und allen Ausgabehashes. Jeder Messlauf hat eine eigene
120-Sekunden-Frist; beim Überschreiten fordert das Skript zunächst kontrollierten
Abbruch an. Eine fehlgeschlagene oder teilweise vorhandene Serie bleibt zur
Prüfung erhalten und wird beim nächsten Aufruf mit demselben Namen abgelehnt.

### Begrenzte Batch-Parallelität

Die abschließende Release-CLI wurde mit denselben Eingaben und Optionen jeweils
mit `--jobs 1` und `--jobs 2` gemessen, drei Läufe je Einstellung. Währenddessen
liefen keine Projektbuilds oder Tests. Jeder Batch enthält zwei Dokumente:
zweimal die oben beschriebene XLSX, zweimal die medienreiche DOCX oder zwei
Kopien eines kontrolliert erzeugten PDFs mit digitalem Kopf und sechs gerasterten
Sätzen. Die PDF-Serie verwendet `--pdf-ocr always`; lokale Vision-Aufrufe bleiben
bei beiden Einstellungen pro Prozess auf eins begrenzt.

`scripts/benchmark_batch.py` erfasst die RSS-Werte der CLI und ihrer laufenden
Kindprozesse über `ps` und summiert sie. Zwischen Abfragen liegen 50 ms Pause;
die Erhebung selbst verlängert den Abstand. Die Zeit reicht vom Prozessstart
bis zur beobachteten Beendigung und enthält diese zeitliche Auflösung. Die
Tabelle zeigt den Median der drei Zeiten und die höchste beobachtete RSS-Summe
in Bytes. Das sind Stichproben, keine garantierten Höchstwerte: kurze Spitzen
können fehlen, gemeinsam verwendete Speicherseiten können mehrfach gezählt
werden, und außerhalb des Prozessbaums laufende macOS-Dienste werden nicht
erfasst. Diese Werte sind deshalb nicht direkt mit `time -l` oben vergleichbar.

| Zwei Eingaben | Zeit, Jobs 1 | Zeit, Jobs 2 | RSS-Summe, Jobs 1 | RSS-Summe, Jobs 2 |
| --- | ---: | ---: | ---: | ---: |
| XLSX, je 384.000 Zellen | 7,25 s | 5,00 s | 84.770.816 | 146.931.712 |
| DOCX, je 64 Bilder | 0,77 s | 0,47 s | 297.484.288 | 573.947.904 |
| PDF, je sechs Scansätze und digitaler Kopf | 0,54 s | 0,54 s | 135.544.832 | 125.714.432 |

XLSX und DOCX sind in dieser Serie mit zwei Workern schneller und benötigen
mehr Speicher. Besonders die kurzen DOCX-Läufe zeigen unterschiedlich erfasste
Spitzen; pro Lauf entstanden nur sechs bis zehn Stichproben. Die PDF-Serie
zeigt keinen belastbaren Laufzeit- oder Speichervorteil. Das separate OCR-Limit
verhindert zwei gleichzeitige Vision-Aufrufe, während andere Parser weiterlaufen
können. Standard bleibt ein Dokument; die wählbare Grenze von vier Dokumenten
ist keine feste RAM-Obergrenze und wurde hier nicht als Leistungsoptimum gemessen.

Alle 18 Batch-Läufe haben dieselben Ausgabedatei-Hashes wie ihre jeweilige
serielle Vergleichsserie. Zusätzlich wurden alle 36 Dokumentergebnisse einzeln
geprüft: je XLSX genau 384.000 verschiedene Zellmarken, je DOCX genau 64
Textmarken und sämtliche 64 Originalbild-Hashes, je PDF jeder Scansatz und der
digitale Kopf genau einmal. Quellenhashes und Ergebnisreihenfolge bleiben gleich.
Separate echte CLI-Proben bestätigen die feste Kollisionsreihenfolge mit einem
langsamen XLSX und einem schnellen CSV, den Quellpaketschutz vor dem ersten
Schreiben sowie SIGINT nach einem fertigen CSV bei noch laufendem XLSX.

#### Batch-Messung wiederholen

Eine neue Fixture-Ablage erzeugen und darin zweite Kopien unter neuen Namen
anlegen; bestehende Dateien werden dabei nicht überschrieben:

```sh
benchmark_root="$TMPDIR/pmt-batch-new"
python3 scripts/benchmark_packages.py generate "$benchmark_root"
python3 - "$benchmark_root" <<'PY'
from pathlib import Path
import shutil, sys
inputs = Path(sys.argv[1]) / "inputs"
for original, second in [("large.xlsx", "second.xlsx"), ("media.docx", "second.docx")]:
    with (inputs / original).open("rb") as source, (inputs / second).open("xb") as target:
        shutil.copyfileobj(source, target)
PY
swift build -c release --product poormans-text
python3 scripts/benchmark_batch.py "$benchmark_root/results" \
  .build/release/poormans-text xlsx \
  "$benchmark_root/inputs/large.xlsx" "$benchmark_root/inputs/second.xlsx" --jobs 1
python3 scripts/benchmark_batch.py "$benchmark_root/results" \
  .build/release/poormans-text xlsx \
  "$benchmark_root/inputs/large.xlsx" "$benchmark_root/inputs/second.xlsx" --jobs 2 \
  --compare "$benchmark_root/results/xlsx-jobs1.json"
```

Für DOCX entsprechend `media.docx`, `second.docx` und ein neues Label verwenden.
Für OCR zwei lokale PDFs und in beiden Aufrufen `--pdf-ocr always` angeben.
Das Skript prüft Quellenbytes, Ergebnisreihenfolge sowie Ausgabehashes zwischen
Läufen und schreibt Rohdaten und Manifeste in die neue Messablage. Inhaltliche
Zählungen anhand der konkreten Quellen bleiben eine zusätzliche Prüfung; reine
Hashgleichheit beweist keinen vollständigen Import. Nach 120 Sekunden fordert
es Abbruch an und wartet fünf Sekunden, bevor es eine weiterhin laufende CLI
beendet. Vorhandene oder unvollständige Messserien bleiben zur Prüfung erhalten.

## Gemeinsame Tabellenbudgets und Bild-Snapshot (0.15.0)

Die Tabellenstufen wurden mit 100.000, 200.000 und 1.000.000 Zeilen zu je
zehn kurzen Textwerten geprüft, als CSV und ODS mit wiederholten Zeilen.
Zusätzlich wurden XLSX-Blätter mit 100, 200 und 1.000 Zeilen zu je 10.000
Spalten geprüft; nur die letzte Spalte enthielt Text, die übrigen Zellen
wurden vom Leser ergänzt. Unabhängige Zeilen-/Wertzählungen beziehungsweise
gezählte Markdown-Zellplätze stimmen bei allen Stufen; Quellen bleiben gleich.
Daraus folgt die gemeinsame Grenze von einer Million Zeilen je Blatt und
zehn Millionen gerenderten Zellen über alle Blätter, inklusive Leerzellen.

Ein lokaler Release-Lauf auf Apple M5 ergab für die größte Stufe:

| Eingabe | Zeilen | Gerenderte Zellen | CLI-Lauf | Maximaler RSS |
| --- | ---: | ---: | ---: | ---: |
| CSV, kurze Textwerte | 1.000.000 | 10.000.000 | 9,727 s | 1.516,72 MiB |
| ODS, wiederholte Zeilen | 1.000.000 | 10.000.000 | 8,739 s | 180,25 MiB |
| XLSX, letzte Spalte gefüllt | 1.000 | 10.000.000 | 4,283 s | 936,91 MiB |

Die CSV-/ODS-Ausgaben umfassen etwa 52 MB. RSS wurde über `wait4` am gesamten
CLI-Prozess gemessen; Nachzählung und Quellenhashes gehören nicht zur Laufzeit.
Einzelmessungen mit lokalem Cache, teilweise gleichzeitig laufenden Messblöcken,
sind keine Zusage für kalte Datenträger oder andere Zelltexte. XML-, Text-,
Link-Scan- und 128-MiB-Ausgabebudgets bleiben zusätzliche Grenzen; eine Datei
kann diese bereits unterhalb des Zeilen-/Zellbudgets erreichen.

Für Bilder entsteht der private Snapshot aus dem gehaltenen Quelldeskriptor:
APFS-Clone, sonst Kopieren mit 256-KiB-Puffer. ImageIO liest über den geprüften
Snapshot-Deskriptor; eine fremde Datei wird nicht durch eigenen Code vollständig
in `Data` kopiert oder abgebildet. Ein direkter `CGDataProvider` wurde verworfen,
weil ImageIO bei der großen BMP sämtliche Quelldaten auf einmal anforderte.

Eine erzeugte 16.384 × 16.384-BMP mit 768 MiB Pixelbereich wurde einschließlich
OCR und Originalasset in 1,548 s bei 954,30 MiB maximalem RSS konvertiert.
Eine 128 × 128-PNG mit auf 768 MiB aufgefüllten Zusatzdaten benötigte 7,392 s
und 788,36 MiB. Beide Ergebnisse und Assets sind bytegleich zur 0.14.0-CLI;
Quellen bleiben unverändert. Das ist kein harter RAM-Deckel: Decoder und Vision
bestimmen einen Teil des Speichers. Die bestehenden Quelldatei-, Frame- und
OCR-Pixelbudgets bleiben erhalten. Die Snapshot-Lösung schließt das Rennen und
vermeidet einen zusätzlichen Voll-Heap, verspricht aber keine generelle Senkung
des Speicherbedarfs der vorhandenen Systemdecoder.
