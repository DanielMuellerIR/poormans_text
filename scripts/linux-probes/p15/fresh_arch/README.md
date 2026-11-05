# P15: frische reguläre Arch-Abnahmebasis

Stand: 2026-11-05. Das offizielle Arch-x86_64-Basisimage und die regulär mit
Pacman aufgelösten Abhängigkeiten sind vorbereitet. Die freigegebenen echten
GUI-Pakete 0.41.10 und 0.41.11 haben Installation, Versionsupgrade und Entfernung
bestanden. CLI/HEIC und die Produktions-GUI liefen dabei als UID 1000 ohne Netz
oder Swift-SDK. Alle 13 bestehenden PDF- und 15 Rasterfälle sind ebenfalls grün.

## Vertrauens- und Umfangsbeleg

Quelle ist das [Docker Official Image Arch Linux](https://hub.docker.com/_/archlinux),
Tag `base-20261101.0.620205`, amd64-Manifestdigest
`sha256:42217d5f09e11d3fe7ad3b309b7fde891d458464dab5d674e629073765610427`.
Das Manifest verweist auf Archs Docker-Quellrevision
`08ea53eee268690de85fe4de2ccf30a8711c909e`, erstellt 2026-11-02T20:06:26Z.
`base.json` enthält die exakten Layerdigests und deren komprimierte Größen.
Eine Digestbindung ist eine Inhaltsbindung; eine zusätzliche Signatur des
Docker-Images wird hier nicht behauptet.

Die Default-Pacman-Policy bleibt unverändert: Repositorypakete sind Required
und TrustedOnly, Datenbanksignaturen Optional/TrustedOnly. Die Initialisierung
mit `pacman-key --init` folgt der offiziellen Imageanleitung. `pacman -Syu`
führt eine vollständige Aktualisierung und normale Abhängigkeitsauflösung durch.
Alle 597 installierten Distro-Pakete weisen in der nativen Pacman-Datenbank
`Validated By: Signature` aus; `pacman -Qk` findet keine fehlenden Paketdateien.
Es wurden weder Signaturprüfungen noch Dependencychecks oder Paket-Hooks
abgeschaltet. Die ephemeren privaten GPG-Schlüssel wurden vor dem lokalen
Image-Snapshot entfernt; die Vertrauensdatenbank bleibt vorhanden.

Basis-Layer plus tatsächlich gecachte Paketarchive/Signaturen umfassen
453.710.291 Bytes (rund 433 MiB), zuzüglich kleiner Datenbank-/Protokolltransfers.
Das Downloadbudget von ungefähr 1 GiB wurde damit eingehalten. Es gibt keine
Hostinstallation, kein Office in dieser Basis und keinen Swift-SDK.
`dependencies.json` enthält Paketversionen, native Validierungsmetadaten und
die unveränderte Policy. Der öffentliche Downloadcache blieb im vorbereiteten Image erhalten: Der
verwendete nichtinteraktive `pacman -Scc`-Aufruf hatte die Defaultantwort Nein
für das vollständige Löschen übernommen. Das betrifft den Speicherbedarf des
Testimages, nicht Signaturprüfung oder Produktfunktion. Die Dockerfile beschreibt denselben Vorbereitungsweg;
rolling Repositoryversionen müssen bei späterem Neubau neu dokumentiert werden.

Der geprüfte lokale vorbereitete Snapshot heißt `pmt-linux-arch-test:20261105`,
ImageID `sha256:333a63abc2687d3c14a4e2e440f0f80e4e295a7db8b935623c8daaa8ba01f713`.
Ein frischer Container daraus bestätigt UID1000, GTK4.24, Poppler26.10,
Pillow13, libheif1.23.7, Tesseract5.5.4 und Pandoc3.11.

## HEIC auf Arch

Die native Probe läuft als UID 1000 ohne Netz gegen die tatsächliche Arch-
libheif1.23.7/libde2651.1.3. RGBA-Alpha, 90°-Orientierung und mehrere Bilder
sowie Header-/Framegrenzen bestehen (`native-positive.json`,
`native-negative.json`). Der korrigierte HEIC-Kandidat wird separat geliefert;
diese Proben sind noch keine Abnahme des fertigen PMT-Pakets.

Der Arch-Paketstand enthält ein automatisch geladenes ffmpeg-Plugin, dessen
Shared-Library-Abhängigkeiten nur optional sind. Ohne ffmpeg9.0.2 scheitert
`heif_init` bereits vor dem nativen Quellenlesen. Der Kandidat meldet dafür
strukturiert unavailable69 statt Dokumentfehler65 und ruft geordnet deinit auf.
`partial-init.json` belegt mit echten nativen Aufrufen genau init/deinit und
null Quellenleseaufrufe; `partial-init-worker.json` belegt Exit69 des echten
Rasterworker-Entrypoints. Danach wurde ffmpeg regulär aus dem eigenen signierten
Cache wiederhergestellt. Es werden keine Pluginfehler ignoriert und keine
Systemdateien zur Decoderfreischaltung umbenannt oder verändert. Die vollständige
Arch-Probenbasis enthält deshalb ffmpeg zusätzlich zu libheif/libde265.

## Ausgeführte Produktabnahme

`verify_lifecycle.py` hat nach Ready den fertigen Release-GUI-Paketstand in
einem eigenen wegwerfbaren Container geprüft. Der Container begann ohne PMT
und ohne SDK; sämtliche Produkt-/Dokumentläufe waren vom Netz getrennt. Nur eigene
Fixtures/Pakete und die Probe werden gemountet, keine Hostprofile oder Desktops.

```sh
docker run --rm --network none \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  -v "$OWN_PROBE_ROOT:/proof" "$PINNED_LOCAL_TEST_IMAGE" \
  python3 -I /proof/delivery/verify_lifecycle.py \
    --package /proof/packages/poormans-text-NEW-1-x86_64.pkg.tar.zst \
    --previous-package /proof/packages/poormans-text-OLD-1-x86_64.pkg.tar.zst \
    --heic-fixtures /proof/native/fixtures --evidence /proof/product.json
```

Die Pakettransaktionen brauchen Containerroot, wie reguläres Pacman. CLI und
GUI laufen als UID 1000 in eigenem Home/TMP/XDG-Verzeichnissen. Die Probe
prüft echte Installation, Versionsupgrade (kein Reinstall-Ersatz), Unicode-CSV,
Outputhashes, HEIC mit OCR aus/an, bytegleiche Originalassets, PNG-Anzahl und
anschließende Entfernung bei unveränderten Benutzerdateien. Die Default-
`LocalFileSigLevel Optional/TrustedOnly` bleibt auch für lokale PMT-Testpakete
unverändert. Deren erforderliche SHA256-Datei prüft die Artefaktintegrität;
eine kryptografische PMT-Releasesignatur wird dadurch nicht behauptet.

`gui_probe.py` hat das tatsächliche installierte Produktionsprogramm unter
privatem Xvfb/DBus durch eine echte AT-SPI-Convert-Aktion bedient. Ein neuer
Konverter oder ein spezieller Testbuild wird nicht verwendet. GTK bekommt
keinen Swift-Library-Pfad; nur der installierte CLI-Launcher setzt seinen
Kindprozess-Laufzeitpfad. Eine eigene PNG-Aufnahme erlaubt die visuelle Prüfung.
Die fertige Anzeige zeigt Completed, den alphanumerischen Testmarker und Grüße
in der Markdown-Vorschau. `product-04111.png` wurde visuell geprüft. Die erste
Aufnahme war vor dem GUI-Ergebnisempfang entstanden; die explizite Wartebedingung
und zweite echte GUI-Konvertierung belegen den abgeschlossenen Zustand. Die
GUI kam unverändert aus dem Releasepaket, ohne Testfeature.

`product-04111.json` nennt Paket-, CLI-, GUI- und Guard-SHA256 sowie die geprüften
HEIC-Quellen. `native-transactions.txt` stammt aus der tatsächlichen ALPM-Historie.
Eine anfängliche Probeannahme mit Unterstrichmarkern wurde an korrektes Markdown-
Escaping angepasst; hierfür wurde kein Produktcode geändert. Die erfolgreiche
Transaktion lautet: 0.41.10 installieren → Upgrade auf 0.41.11 → entfernen. Eine weitere reguläre
Installation derselben Version 0.41.11 diente der gezielten fertigen GUI-Anzeige und den
bestehenden Regressionen; danach wurde erneut regulär entfernt.

Die zwei unveränderten Probequellen stehen unter `regressions/`; Ergebnisse unter
`pdf-04111.json` (13 Fälle) und `raster-04111.json` (15 Fälle). Dafür wurde zuvor
zusätzlich nur das offizielle signaturvalidierte qpdf 12.4.2-Paket regulär mit
`pacman -Syu` ergänzt (1,05 MiB Download). Nach der finalen Entfernung waren
44 eigene Fixture-/Outputdateien bytegleich; CLI-/GUI-/Runtime-/Desktopdateien
und der Paketeintrag fehlten. Es blieben keine lebenden UID1000-Prozesse.

Nicht belegt sind damit echte Desktopintegration, native Wayland-Sitzung und
Portal-/Clipboardparität über verschiedene Desktops. Die separate Möglichkeit
ist in `WAYLAND-ASSESSMENT.md` beschrieben; keine Compositorinstallation wurde
begonnen. GTK4 bleibt die gemeinsam freigegebene reversible Entwicklungswahl.
