# Linux-RTFD: statische Rasteranhänge

Gezielter Kandidat auf Root 0.41.12/build97; vier Dateiänderungen, keine Repo-/Git-Schreibarbeit und kein Versionsbump. Alle vier ursprünglichen Dateihashes stimmen bei Lieferung weiterhin mit Root überein. Root übernimmt und versioniert selbst. Patch: `rtfd-static.patch`.

`LinuxRTFDPreparation` nutzt den vorhandenen `RasterImageBackend.validate` statt des direkten PNG-Gates. Erlaubt sind PNG, JPEG (jpg/jpeg), TIFF (tif/tiff), GIF, WebP und HEIC, jeweils genau ein dekodiertes Bild und passender tatsächlicher Formattyp. Andere Typen, falsche Dateiendungen und Mehrframes werden vor Veröffentlichung abgewiesen. Die bisherige FD-geprüfte Paketkopie und Verweis-/Markerlogik bleiben erhalten. Der generische HTML-Schlussweg kopiert Originalbytes an derselben Textposition; wie bisher schreibt er die Dateiendung klein (z. B. .JPEG→.jpeg), behält den Endungsalias bei und generiert keine Rasterersatzdatei.

APNG umgeht das Gate nicht: vorhandenes `CPMTLinux/image.c` erkennt acTL und liefert UNSUPPORTED; `RasterImageBackend` nutzt dann den bestehenden Pillowdecoder. Die neue RTFD-Prüfung lehnt dessen frameCount>1 ab. Kein C-/Pythondecoder wurde geändert. Die beiden gezielt gefangenen Fehlerarten sind echte Bildvalidierungsfehler; PlatformBackendUnavailable, Abbruch, Timeout und Dateisystemfehler bleiben unverändert erhalten.

Der einzige zusätzliche `RichTextConverter`-Hunk liegt im vorhandenen Linux-Block: TIFF/HEIC erhalten `rtfd.viewerCompatibility` mit dem ausdrücklichen Hinweis, dass Originalbytes erhalten bleiben, manche Markdownviewer diese Typen nicht anzeigen und kein PNG-Ersatz erzeugt wurde. Der Macpfad und die gemeinsame HTML-Schlussstrecke bleiben unverändert. Kein Vektor/PDF-/Inline-pict-/Objektimport; keine Mehrframe-Unterstützung.

## Ausgeführt

- Swift 6.2.1/Noble-Vollbuild im vorhandenen `pmt-linux-builder`: 74,74 s. Keine Installation/Downloads. Neun echte Linux-RTFD-XCTests: 0 Fehler, 1,48 s. Neue Tests prüfen statische JPEG/TIFF/GIF/WebP, Byteidentität/Originalfolge sowie GIF/TIFF/APNG/WebP mit mehreren Frames und Format-Endungs-Mismatch. Alle bestehenden RTFD-Unit-Negativfälle bleiben grün.
- CachyOS: 24 echte CLI-Fälle mit qualifiziertem Pandoc 3.1.3; alle Erwartungen erfüllt. Host hat kein libheif: beide HEIC-Fälle ehrlich 69/keine Ausgabe. Sechs neue statische JPEG/JPEG-Alias/TIFF/TIFF-Alias/GIF/WebP-Fälle erfolgreich; unabhängige BEFORE/Bild/AFTER-Reihenfolge, Originalassetbytes/-hashes, Suffix und Diagnosen geprüft. Alle bisherigen Paket-/RTF-/Verweis-/Symlink-/FIFO-/beschädigten Bildfälle bleiben geprüft; Fehler veröffentlichen nichts.
- Vorhandenes Noble-Image `pmt-heic-probe:local`, SHA `c6c14c83dd5f81703172f5cbb766af5a47c76a9cb638a88efba7bd31226f0481`, Pillow10.2/libheif: dieselben 24 CLI-Fälle erfüllt, einschließlich statischem HEIC mit byteidentischem Original an der Textposition und Kompatibilitätshinweis. Mehrbildriges HEIC: 65/keine Ausgabe. Keine Netzwerkverbindung oder Imageänderung.
- Echtes vorhandenes Buildimage ohne Pillow: JPEG-RTFD ergibt 69/keine Ausgabe. Echter Timeout:124/keine Ausgabe. SIGTERM nach Beobachtung eines echten Python-inspect-Workers:130/keine Ausgabe, keine eigenen Restkinder. Quelle blieb bytegleich. Keine Stubs.

`evidence.json` enthält die 48 Matrixeinzelfälle mit Markdown, Output-/Assethashes, Diagnosen, Quellenhashen, drei Kontrollbelegen und ursprünglichen/neuen Dateihashes. Die Quellen wurden in beiden erfolgreichen Matrizen gegen vor dem Lauf erfasste Hashes verglichen. Build-/Unit-Belege liegen daneben. Keine Mac-, GUI- oder universelle Viewer-Abnahme wird behauptet.

## Reproduktion

Patch in eine isolierte Arbeitskopie übernehmen. Mit vorhandener Swift6.2+-Toolchain auf Linux bauen und `RTFDTests` ausführen. Die erweiterte vorhandene Probe liegt im Patch unter `scripts/linux-probes/p10-rtfd/verify_rtfd.py`:

```sh
python3 scripts/linux-probes/p10-rtfd/verify_rtfd.py \
  --root "$NEW_OWN_TEMP/cases" --cli "$RUNTIME/bin/poormans-text" \
  --pandoc "$QUALIFIED_PANDOC" \
  --heic-single "$SYNTHETIC_HEIC/single.heic" \
  --heic-multi "$SYNTHETIC_HEIC/multi.heic"
```

Der Probe-Root darf noch nicht existieren. Bereits vorhandenes Pillow erzeugt die kleinen unabhängigen Rasterfixtures; HEIC-Optionen sind optional und verwenden die vorhandenen synthetischen P09-Fixtures, ohne Download. Die Probe ermittelt echte optionale HEIC-Fähigkeit über den Katalog. Laufzeitlayout bin/lib samt Core-Ressourcenbundle und ProcessGuard erforderlich. Für Debug-Builds braucht die eigene Testlaufzeit zusätzlich die passende libswiftSwiftOnoneSupport.so.

`control_probe.py` ist der kleine separate Kontrolllauf; erwartet eigene runtime/bin+lib unter seinem Verzeichnis und `PMT_TEST_PANDOC` als qualifizierten absoluten Pfad. Bei Übernahme wurden nur die private Pandoc-Pfadkonstante in eine Umgebungsvariable geändert; diese Portabilisierung ist nicht als weiterer Produktlauf gezählt.

## Ehrliche Testaufbaugrenzen

Ein erster isolierter Debug-CLI-Aufruf stoppte vor dem Produktstart wegen fehlender Debugbibliothek; diese wurde ausschließlich in der eigenen Testlaufzeit ergänzt. Ein neuer Probeassert erwartete zunächst unveränderte Großschreibung der Endung; er wurde an das bereits bestehende gemeinsame .JPEG→.jpeg-Verhalten angepasst. Die Host-HEIC-Erwartung wurde anhand des tatsächlich fehlenden libheif auf 69 korrigiert; der positive Codecfall wurde unabhängig im bestehenden Noble-Image ausgeführt.

Die erste Abbruchbeobachtung suchte den ursprünglichen Scriptnamen. Der echte Runner verwendet FD-Aliase; die korrigierte Beobachtung erfasst den Python-inspect-Aufruf im eigenen Nachkommenbaum. Erst dieser erfolgreiche Lauf zählt als Abbruchbeleg.

Separater bestehender Randfall: Wird die CLI direkt Docker-PID1, scheitert die Prozesssupervision mit74, weil `pmt_process_pidfd_open_owned` nur while(current>1) prüft und ancestor1 nicht erreicht. Die fehlende-Pillow-Kontrolle verwendete deshalb einen eigenen PID1-Shell-Elternprozess. Dieser Fund wurde Root gemeldet; kein fachfremder Fix ist im RTFD-Patch enthalten.

Eigene Buildcache-/Runtime-/Sourcekopien und temporäre Container sind bei Abschluss entfernt. Kleine Lieferung bleibt zur Rootübernahme erhalten; `cleanup.json` dokumentiert den Abschluss.
