# P09: optionaler HEIC-Decoder

Stand: 2026-11-05, integriert in 0.41.11. Der gemeinsame Swift-Kern verwendet
seinen isolierten Rasterworker und die öffentliche lokale libheif-C-API.
Bibliothek und HEVC-Decoder werden ausdrücklich als Distro-Pakete installiert,
nicht gebündelt oder automatisch geladen. Der [Linux-Build](../LINUX-BUILD.md)
nennt die Paketnamen. Swift bleibt der Konvertierungskern.

Originalbytes bleiben unverändert als verlinktes Asset erhalten. Jedes
Top-Level-Bild erhält zusätzlich eine RGBA-PNG-Darstellung; Standard-OCR arbeitet
auf einem gesonderten weißen Raster. libheif wendet Orientierung einmal an.
Die Diagnose `image.heicRender` benennt 8-Bit-Darstellung sowie Verluste bei
HDR, Farbprofilen, Hilfsbildern und Metadaten. Zeitbasierte HEVC-Sequenzen,
AVIF und Mac-Funktionsgleichheit werden nicht behauptet.

Der Formatkatalog enthält genau eine Bildzeile. Nur dort wird der optionale
HEVC-Decoder mit höchstens zehn Sekunden geprüft; reine Formatdeklarationen
starten keinen Prozess. Fehlende Bibliothek, Plugins oder fehlgeschlagene
Initialisierung ergeben für HEIC Status 69; PNG bleibt verfügbar. Die interne
Ordnererkennung behält HEIC auch ohne Decoder, damit solche Dokumente sichtbar
fehlschlagen statt still übersprungen zu werden. Defekte Dokumente und
überschrittene Dokumentbudgets ergeben 65.

Die unveränderbare Snapshotdatei liegt außerhalb des beschreibbaren Workers
und wird einzeln read-only gebunden. Der bestehende ProcessRunner erzwingt
PID-/Netzisolation, Timeout und Cleanup. Vor Decoderstart gelten 1,5 GiB
Adressraum, 300 MiB pro Ausgabedatei und 128 Deskriptoren. Quellen sind auf
1 GiB und 1000 Top-Level-Bilder begrenzt. Sowohl interne als auch angezeigte
Abmessungen dürfen je Achse 32768 und je Bild 64 Millionen Pixel nicht
überschreiten; insgesamt gelten 256 Millionen Pixel. Nach Decode werden
Dimensionen, Stride und RGBA-Plane erneut geprüft. Native Objekte und
init/deinit sind auch auf Fehlerpfaden ausgeglichen. Ein Tile-Decode-Thread
begrenzt keine sämtlichen codec-internen Threads.

Die [Produktbelege](P09-HEIC-EVIDENCE/product-04111.json) gehören zur tatsächlichen
Release-Laufzeit 0.41.11: zehn CLI-Fälle ohne Swift-SDK auf Ubuntu 24.04,
positiver PNG-/HEIC-Mischordner sowie sieben Fälle und sichtbarer Mischordnerfehler
auf dem Host ohne libheif. Quellen, Originalassets, Frameanzahl, Berichts-/PNG-
Hashes und fehlende Veröffentlichung bei Fehlern werden geprüft. Die gesamte
Swift-Suite besteht mit 342 ausgeführten, davon acht übersprungenen Tests und
null Fehlern. Die Probequellen stehen unter `scripts/linux-probes/p09/heic`.

Die getrennt gekennzeichneten `candidate-*`-Belege dokumentieren den vorangehenden
isolierten Kandidaten: Alpha und 90°-Orientierung, mehrere Bilder, Ablehnung von
1001 Bildern und übergroßem Header vor Decode, fehlendes Decoderplugin sowie
15 bestehende Raster-/OCR-Fälle. Sie werden nicht nachträglich als Prüfung des
fertigen Releasepakets ausgegeben. Die frische Arch-Paketabnahme wird separat
im [Paketbericht](P15-CLI-PACKAGES.md) ergänzt.

Arch-libheif 1.23.7 scheitert bei diesem Distrostand ohne das optionale ffmpeg
bereits in `heif_init`, weil es automatisch geladene Plugins betrifft. Der
Helper meldet das strukturiert als unavailable und beendet die Initialisierung
geordnet, ohne Quelldaten nativ zu lesen. Ein echtes init/deinit-Paar und null
Quellenleseaufrufe sind im Kandidatenbeleg nachgewiesen. Die reguläre Installation
von ffmpeg behebt diesen konkreten Distrozustand; PMT verändert keine Plugins.

Die ABI wurde gegen den [offiziellen Header 1.17.6](https://github.com/strukturag/libheif/blob/v1.17.6/libheif/heif.h)
und der Initvertrag gegen [1.23.7](https://github.com/strukturag/libheif/blob/v1.23.7/libheif/api/libheif/heif_library.h)
geprüft. libheif steht laut [Arch-Paketquelle](https://archlinux.org/packages/extra/x86_64/libheif/)
unter LGPL-3.0-or-later; Ubuntu benennt den [separaten libde265-Decoder](https://packages.ubuntu.com/noble/libheif-plugin-libde265).
Der x265-Testencoder erzeugt nur synthetische Fixtures und gehört nicht zum
Produktbedarf. Updates erfolgen über die Distribution. Eine spätere Bündelung
wäre eine eigene Lizenz-/Distributionsprüfung.

Offen bleiben reale Kameraarchive, HDR-/ICC-Treue und der aktuelle native
Mac-Vergleich. Bestandene synthetische Proben ersetzen diese Abnahmen nicht.
