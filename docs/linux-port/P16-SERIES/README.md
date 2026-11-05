# P16 – begrenzte CLI-Neustartserie

2026-11-05. **48 echte Neustarts bestanden:** 40 erfolgreiche Konvertierungsjobs,
8 absichtlich ungültige Eingaben mit Exit 65. Gesamtlauf 25.666 s; alle 374 fallbezogenen
Prüfungen erfolgreich. Dies ist ein begrenzter lokaler Seriennachweis, keine
Hardware-/Performancegleichheit, Langzeit-/GUI-Speicherprüfung oder vollständige
Formatqualifikation.

## Exakter historischer Stand

Alle 48 laufenden CLI-Prozesse wurden über `/proc/PID/exe` einzeln beobachtet und
gehasht. Ausnahmslos:
`c70a369fc76d0a5988931f5e32e4b16b57cc372bf3299e43b203c86b8c0ec157`,
Version 0.41.10. Keine fehlenden oder gemischten Laufhashes.
[c70.json](c70.json) hält diesen historischen Stand fest. Die spätere Ubuntu-
LibreOffice-Korrektur am read-only-Konfigurationsmount ist darin **nicht** enthalten;
ein neuer Stand benötigt einen frischen Serienlauf und eigenen Beleg.

## Umfang und Belege

Fünf wechselnde Runden mit CSV, DOCX, XLSX, MBOX, PNG, PDF, RTF und DOC. Variiert
werden Frontmatter, Textbundle, Fortschritt, jobs 4, DOCX-Änderungsmodus,
XLSX-TSV-Ausgabe, PNG-OCR und PDF-OCR off/auto/always mit Englisch. Eine CSV-Runde
konvertiert tatsächlich einen Ordner mit zwei Dateien parallel; MBOX enthält zwei
Nachrichten. Das sind 40 positive CLI-Jobs mit 41 erzeugten Einzelkonvertierungs-
Reports; nicht jede Nachricht wird als zusätzlicher CLI-Neustart gezählt.

- Quellen liegen ausschließlich im eigenen temporären Bereich und sind 0444.
  Nach jedem Fall bleiben alle Quellbytes, Größen, Inodes, Modi und mtimes gleich.
- Alle 41 Reports passen zu den eigenen Quell-SHA256/Bytezahlen.
- Alle 84 gemeldeten Ausgabedateien stimmen bei SHA256 und Bytezahl.
- Alle 74 vorhandenen Source-Mappings bleiben innerhalb der richtigen Ausgabedatei;
  Prefix, Bereich und Suffix sind jeweils als UTF-8 dekodierbar. Das prüft Byte-
  grenzen, keine semantische Positionsgleichheit. Nicht alle Formate liefern Maps.
- Nach jedem CLI-Ende und abschließend: keine lebenden oder ungeernteten eigenen
  Nachkommen. Der Prüfer nutzt einen eigenen Linux-Subreaper; notwendiger Cleanup
  signalisiert ausschließlich zuvor gebundene, als eigene Kinder geprüfte pidfds.
  In diesem Lauf mussten 0 adoptierte Prozesse beendet oder nachgeerntet werden.
- Alle 8 Fehlerfälle erzeugen weder ein Ausgabeziel noch zurückgebliebenes Staging.

Die Quelle/Fixtures stammen aus vorhandenen Projektproben: WordProcessing-
Referenz-DOC/DOCX, P09-PNG-Zeichnung, P13-MBOX, Linux-PDF-Wortlückenfixture und der
P06-RTF-Encodingfall. CSV/XLSX werden klein und unabhängig aus bekannten Zellwerten
gebildet; kein Ersatzkonverter, Modell oder Produktstub. Die unveränderten
WordProcessing-Quelldateien werden nur in den eigenen Probenordner kopiert.

## Reproduktion

Linux, Python 3.11+ mit vorhandenem Pillow/DejaVuSans sowie eine regulär gebaute CLI
und ausdrücklich gewähltes vorhandenes Pandoc. Keine Downloads oder Installation.

```sh
python3 scripts/linux-probes/p16/verify_series.py \
  --cli ./poormans-text --repo . --pandoc /absoluter/pfad/pandoc \
  --root /neuer/nicht-vorhandener/probenordner
```

Die Probe überschreibt keinen vorhandenen Zielordner, begrenzt die Serie auf 180 s,
einen einzelnen Prozess auf 15 s und bricht bei zwei gleichen fehlgeschlagenen
Prüfungen ab. Der abschließende Uniformitätscheck lehnt gemischte Runtime-Snapshots
ab. Bei parallelem CLI-Neubau deshalb besser die fertige Runtime unverändert
halten oder einen ausdrücklich isolierten Runtime-Snapshot verwenden.

Eine zusätzliche Testsandbox kann User-/PID-/Netzwerk-Namespaces blockieren. Eine dadurch
fehlgeschlagene Backendprobe ist kein Formatbeleg; Hostvoraussetzungen müssen dem
regulären Produktlauf entsprechen. Rohstdout/-stderr und Ergebnisbäume enthalten
absolute Aufrufpfade und bleiben temporär; der kleine JSON-Beleg enthält relative
Dateinamen und Hashes.

Eine erste vorbereitende Serie stoppte nach 14 Neustarts korrekt nach zwei gleichen
Assertions: Der Prüfer hatte bei MBOX nur index.md statt der gemeldeten Dokument-
dateien gelesen. Die Nachrichtentexte waren vorhanden. Nach Korrektur dieser
Prüfannahme lief die hier dokumentierte Serie mit 48 Neustarts vollständig in einem neuen Root.
Es gab dabei keine Produktkorrektur und keinen reproduzierten Produktfehler.

Nach der Auswertung wurden die entbehrlichen Roh-Ausgabebäume und Prozesslogs
bereinigt. Der c70-JSON-Beleg und die kleinen ursprünglichen Quellen bleiben
aufbewahrt. Ein neuer Reproduktionslauf erzeugt eigene neue Rohresultate.

## Wiederholung nach Ubuntu-Office-Korrektur

[b823.json](b823.json) wiederholt dieselben 48 Neustarts am tatsächlich geänderten
Release-ELF `b82333856d0b4fe6114f620094fb263825b53433eafd6a84e0c06282bc946395`.
Die Laufzeit betrug 25,400 s; alle Einzelprozesse hatten denselben Hash, alle
Fallprüfungen und die abschließende Uniformitätsprüfung bestanden. Es blieben
keine lebenden oder ungeernteten eigenen Nachkommen. Dies ist der zusätzliche
Beleg nach dem eng read-only eingebundenen `/etc/libreoffice`; die erste Serie
wird nicht nachträglich umetikettiert. Ein später erneut geänderter ELF benötigt
einen eigenen Nachweis.

## Finale Wiederholung 0.41.12

[Finaler Beleg](../P16-04112/series.json): derselbe 48-Fall-Umfang besteht am
CLI-ELF `2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c`
in25,800s; 374/374 Prüfungen, unveränderte Quellen, keine Restnachkommen.
Der Prüfer liest die erwartete Version jetzt aus dem ausdrücklich gewählten Repo,
statt historische .10 fest vorauszusetzen. Eine neue Runtime darf weiterhin
nicht während der Serie ausgetauscht werden. Der erste neue Sandboxversuch war
kein Produktbeleg; [Einordnung](../P16-04112/README.md).
