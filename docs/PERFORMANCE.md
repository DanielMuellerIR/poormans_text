# Paketverarbeitung: Messung 2026-09-05

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

## Vergleich unmittelbar vor und nach der Paketänderung

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

## Frühere Gesamtbaseline

`ad476f4` liegt vor der Fortschritts-/Abbrucharbeit und ist deshalb kein isolierter
Vergleich für die Paketänderung. Sie bleibt zur Einordnung dokumentiert:

| Eingaben | Zeit | Speicher |
| --- | ---: | ---: |
| XLSX, 384.000 Zellen | 3,33 s | 130.383.872 |
| DOCX, 64 Bilder | 0,28 s | 166.281.216 |
| 200 CSV-Dateien | 0,23 s | 17.661.952 |

Auch mit dieser Gesamtbaseline stimmen sämtliche Ausgabedatei-Hashes überein.

## Wiederholen

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
