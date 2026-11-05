# Root-Release 0.41.13: RTFD-Abschlussprobe

Am 2026-11-05 wurde der exakte Root-Release geprüft, keine weitere Kandidatenkopie und kein Debug-Build:

- CLI SHA256 `26470eaf5d0b474e7f164882683b339ffc63b75d20a3ecdd6856729883f8f460`.
- Guard SHA256 `cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520`.
- Process-C-Quelle SHA256 `56066ab58b87fe3f614ccac00a20caa0005872081f29204a385ef57990dddc9d`.

25/25 echte CLI-Fälle mit der unveränderten Root-Probe `scripts/linux-probes/p10-rtfd/verify_rtfd.py` erfüllt: zwölf erfolgreiche Konvertierungen, 13 kontrollierte Fehler. PNG, JPEG/Endungsalias, TIFF/Endungsalias, GIF, BMP, WebP und HEIC behalten Originalassetbytes und die BEFORE/Bild/AFTER-Position. TIFF/HEIC liefern die ehrliche Viewer-Kompatibilitätsdiagnose. BMP-Quell-/Assethash `cfb3fa514861b924669bb08e35ee7fa61223a13bcc33a5017c447a191a990a87`, HEIC-Quell-/Assethash `d3ba28ae03b0459390e6db6df595c67136f66c6bc1aa12457efefa003a24192b`. Mehrframe-GIF/TIFF/APNG/WebP/HEIC, beschädigte/falsch benannte Bilder und unsichere/fehlende Verweise scheitern mit65 ohne Ergebnisordner. Alle Paketquellen bleiben bytegleich; der absichtlich nicht referenzierte Anhang wird weiterhin diagnostiziert.

Umgebung: vorhandenes Noble-HEIC-Testimage SHA `c6c14c83dd5f81703172f5cbb766af5a47c76a9cb638a88efba7bd31226f0481`, Pillow10.2.0/libheif.so.1, **kein Swift-SDK** (shutil.which("swift")=null), bereits qualifiziertes Pandoc3.1.3. Kein Download, keine Installation oder Imageänderung. Netzwerk und Container-RootFS gesperrt. Root-bin inklusive Ressourcenbundle, lib, Root-Probe, vorhandene synthetische HEIC-Fixtures und Pandoc nur lesend eingebunden; allein der neue eigene /tmp-Ausgabeordner war schreibbar. Kein UI-Verzeichnis eingebunden und keine volle Runtimekopie erstellt.

33 Datei-SHA256 aus bin/lib/Core-Ressourcen, fünf HEIC-Quellfixtures, Probe und Process-C-Quelle vor und nach dem Lauf identisch. `evidence.json` enthält beide vollständigen Hashlisten, Einzelfälle, Markdown, Diagnosen, Output-/Assethashes und Quellenhashbelege. `run.log` ist die erfolgreiche originale Probeausgabe mit portablen `$WORK`-Pfaden. Keine Wiederholung der bereits belegten69/124/130-Kontrollen, keine Behauptung einer neuen gesamten Testsuite-/Mac-/GUI-Abnahme.

Reproduktion: das bestehende Image netzlos/read-only mit UID1000 starten. `$RUNTIME/bin` nach `/runtime/bin`, `$RUNTIME/lib` nach `/runtime/lib`, vorhandene Root-Probe nach `/probe.py`, qualifiziertes Pandoc nach `/pandoc` und synthetische HEIC-Fixtures nach `/heic` jeweils read-only binden; neuer eigener Ausgabeordner nach `/out`. Verschachtelte Namespaces wie bei der vorhandenen P09-Testumgebung freigeben. Aufruf:

```sh
/usr/bin/python3 /probe.py --root /out/run \
  --cli /runtime/bin/poormans-text --pandoc /pandoc \
  --heic-single /heic/single.heic --heic-multi /heic/multi.heic
```

Der Probe-Root darf noch nicht existieren. Kein Git-/Repo-Write. Container mit `--rm` beendet und eigener lokaler Fixture-/Outputbaum entfernt; kleine Belege bleiben erhalten, siehe `cleanup.json`.
