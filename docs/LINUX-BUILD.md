# Linux-Entwicklungsstand

Die Linux-Portierung verwendet denselben Swift-Konvertierungskern wie macOS.
P05 stellt Build und Plattformgrenzen her; dies ist noch keine vollständige
Linux-App oder Distributionsfreigabe. PDF, Standard-OCR und Bilder verwenden
explizite lokale Backends; RTFD unterstützt zunächst geprüfte lokale statische
PNG-, JPEG-, TIFF-, GIF-, BMP-, WebP- und optionale HEIC-Anhänge. Mehrframes
werden abgewiesen; TIFF/HEIC bleiben Originaldateien mit Viewer-Kompatibilitätshinweis. Legacy-DOC verwendet optional LibreOffice mit expliziten sicheren UNO-Ladeparametern. HEIC verwendet optional den lokalen libheif-HEVC-Decoder; strukturierte OCR bleibt nicht verfügbar.
Die vorhandene Mac-App bleibt nativ.

## Lokal bauen

Benötigt werden Swift 6.2 oder neuer, Python 3 sowie die Entwicklungsbibliotheken
für zlib und libpng. Alternativ lässt sich ausdrücklich ein vorhandenes lokales
Docker-Buildimage wählen:

```sh
docker build -t pmt-linux-builder -f scripts/LinuxBuild.Dockerfile .
PMT_LINUX_BUILD_IMAGE=pmt-linux-builder ./build.sh debug
```

Ohne `PMT_LINUX_BUILD_IMAGE` verwendet `./build.sh` die native Swift-Installation.
Das Skript lädt kein Dockerimage automatisch herunter. SwiftPM-Abhängigkeiten
werden beim ersten Build aufgelöst; danach kann mit vorhandenem Cache offline
gebaut werden. Die Konvertierung selbst lädt keine Werkzeuge oder Inhalte nach.

Der Build erzeugt nur lokale Artefakte: den Launcher `poormans-text` im Repo-Root
und sein Paket unter `.build/linux-runtime`. Darin liegen die echte CLI und der
Prozessguard nebeneinander. Swift-Laufzeitbibliotheken sowie benötigte XML-/ICU-
und Bildbibliotheken werden für den Start ohne Swift-SDK mitgeliefert.
glibc und der ELF-Loader bleiben Systemabhängigkeiten.
Vorhandene Lizenz-/Hinweisdateien der Systembibliotheken, Swift-Laufzeit und
SwiftPM-Abhängigkeiten liegen unter `licenses`. Die abschließende Prüfung eines
verteilbaren Pakets einschließlich aller Lizenzbeigaben gehört zu P15.

Linux verwendet `Package.linux.resolved` und eine temporäre Quellkopie außerhalb
des Repositories. Der Mac-Lockfile `Package.resolved` wird dadurch nicht verändert.
Native und Docker-Buildcaches bleiben getrennt. Vorherige Laufzeiten/GUI-Artefakte
bleiben nach einem erfolgreichen Austausch als `linux-runtime-old-*` beziehungsweise
`ui-old-*` erhalten. Fehlgeschlagene UUID-Stages werden ebenfalls erhalten statt
unbekannte nachträgliche Inhalte zu löschen. Sie dürfen nach eigener Prüfung
gezielt entfernt werden; der Build führt keine pauschale Bereinigung aus.

Die gemeinsamen und Linux-spezifischen Unit-Tests lassen sich in einer isolierten
Quellkopie mit `swift test --jobs 6` ausführen. Der echte Produktprüflauf lautet:

```sh
python3 scripts/linux-probes/verify_product.py ./poormans-text --pandoc /pfad/zu/pandoc
```

Der Prüflauf erzeugt seine Dokumente temporär und räumt sie selbst auf.

## Optionale GTK-Oberfläche

Die Oberfläche ist ein dünner Rust-/GTK-Adapter derselben lokalen CLI. Sie bietet
Datei-/Ordnerauswahl, mehrere Quellen, Optionen, sichere Textvorschau,
Fortschritt/Abbruch, Diagnosen, Assets, Clipboardformate und CLI-Profile.
PDF-Seiten und Bildframes lassen sich passiv neben verifizierten UTF8-Referenzen
vergleichen; Anpassen und 25–400 % manueller Zoom verwenden dieselben begrenzten
Vorschaupixel ohne neue Konvertierung. Clipboardoriginale liegen bis 64 MiB in versiegelten memfds; die
gebundene private Quelle ist für Konvertierung, Profile und Vergleich dieselbe.
Der gesamte private /dev-Baum ist für die äußere CLI schreibgeschützt.
Die Vorschau führt weder HTML noch Links aus. Allgemeine GUI-Einstellungen
werden noch nicht automatisch gespeichert; Profile können bewusst gespeichert
werden. Dies ist eine Entwicklungsvorschau, keine vollständige Desktopabnahme.

Für den nativen Bau sind Rust ab 1.92, GTK 4 ab 4.12 und dessen
Entwicklungsbibliotheken nötig. Der qualifizierte Ubuntu-24.04-Bau verwendet
eine gepinnte Rust-Toolchain; er vermeidet neuere Host-glibc-Abhängigkeiten:

```sh
# Einmalig die gelockten öffentlichen Crates bewusst bereitstellen:
cargo fetch --locked
# Einmalig das lokale GUI-Buildimage erstellen:
docker build -t pmt-linux-gui-builder -f scripts/LinuxGUIBuild.Dockerfile .
PMT_LINUX_BUILD_IMAGE=pmt-linux-builder PMT_LINUX_GUI_BUILD_IMAGE=pmt-linux-gui-builder ./build.sh --with-gui release
./linux/run.sh
./release.sh --no-build --with-gui
```

Der eigentliche Cargo-Bau läuft immer `--locked --offline`; Container ziehen
keine Images automatisch nach. Native und Ubuntu-Targets sind getrennt.
Die Registrydaten werden ohne Cargo-Credentials oder Konfiguration in den
lokalen Buildcache übernommen; `PMT_CARGO_HOME` kann einen ausdrücklich
bereitgestellten Cache wählen. Pakete weisen jedes ELF oberhalb glibc 2.39 ab.

GTK benutzt die Systembibliotheken. Nur der CLI-Kindprozess erhält die
mitgelieferte Swift-Bibliothekssuche; sie wird nicht in den GTK-Prozess injiziert.
Die Oberfläche wird durch einen eigenen PID-/Netznamespace beaufsichtigt:
Ohne bestätigten namespace-pidfd startet die CLI nicht. Der Prozessbaum ist vor
der Abschlussmeldung beendet. Unter `ui/THIRD-PARTY-NOTICES.txt` stehen die
unveränderten Lizenztexte und Copyright-Hinweise der gelockten Rust-Crates
samt Hashindex sowie die Hinweise der tatsächlich verwendeten Rust-Toolchain.
GTK und seine GNOME-Systembibliotheken bleiben separat lizenzierte Abhängigkeiten.

GUI-Pakete ergänzen `poormans-text-app` und eine `.desktop`-Datei; sie setzen
keine Dateityp-Standardzuordnungen. Ohne `--with-gui` bleiben CLI-Pakete unabhängig
von GTK installierbar. `./install.sh` installiert unter Linux bewusst nichts;
die erzeugten nativen Pakete sind ausdrücklich mit dem Paketmanager zu verwalten.

## Laufzeit und Grenzen

```sh
./poormans-text --formats --json
./poormans-text --json --report --output /neues/ziel -- /pfad/quelle.docx
```

Pandoc und `/usr/bin/bwrap` ab 0.9 müssen für externe Konvertierungen lokal vorhanden
sein. Der PMT-Prozessguard gehört zum lokalen Build. Optionale Backends verwenden
ausdrücklich installierte Distributionspakete:

| Fähigkeit | Mint/Ubuntu | Arch |
| --- | --- | --- |
| Rasterdecoder | `python3-pil` | `python-pillow` |
| HEIC (optional) | `libheif1`, `libheif-plugin-libde265` | `libheif`; beim geprüften Pluginstand zusätzlich `ffmpeg` |
| PDF | `python3-gi`, `python3-cairo`, `python3-gi-cairo`, `gir1.2-poppler-0.18` | `python-gobject`, `python-cairo`, `poppler-glib` |
| Legacy-DOC | `libreoffice-writer`, `python3-uno`, Pandoc | `libreoffice-fresh`, zum System-Python passende UNO-Bindings, Pandoc |
| Standard-OCR | `tesseract-ocr` und gewählte Sprachpakete | `tesseract` und gewählte `tesseract-data-*` |

Es gibt keine automatischen Paket- oder Sprachdownloads. Ohne explizite
Sprachauswahl verwendet Tesseract installiertes Englisch, andernfalls die erste
installierte Erkennungssprache; eine Diagnose nennt diese Wahl. Dies ist keine
automatische Mehrsprachenerkennung wie bei Vision. Der Formatkatalog meldet
fehlende Werkzeuge und Plattformbackends; ein vorhandenes Werkzeug allein
belegt nicht die vollständige Unterstützung jeder Dokumentvariante.

Statische PNG-Assets werden mit libpng vollständig geprüft; weitere Rasterformate
und APNG verwenden Pillow im begrenzten isolierten Hilfsprozess. Alle Frames
werden validiert; Originalbildbytes bleiben erhalten. Für OCR werden EXIF-Lage,
Alpha auf weißem Hintergrund und ein gemeinsames Pixelbudget berücksichtigt.
Der Decoder begrenzt Quelldaten, Framezahl, Pixel, Speicher und Prozesslaufzeit.
HEIC übernimmt die Originalbytes und erzeugt für jedes Top-Level-Bild zusätzlich eine 8-Bit-RGBA-PNG-Darstellung. HDR, Farbprofile, Hilfsbilder und Metadaten besitzen ausdrücklich benannte Grenzen; siehe [HEIC-Nachweis](linux-port/P09-HEIC.md). RTFD unterstützt geprüfte lokale statische PNG-, JPEG-, TIFF-, GIF-, BMP-, WebP-
und optionale HEIC-Anhänge; mehrere Frames, Inline-Bild-/Objektziele und komplexe
Attachmentnamen werden ausdrücklich abgewiesen. Originalbytes bleiben erhalten.

PDF übernimmt Poppler-Text, Positionen, Bilder, sichere Links und Annotationen.
Die gemeinsame Zeilenlogik erhält Lesereihenfolge, optionale Randbereinigung
und konservative Dehyphenation. Standard-OCR ergänzt Digitaltext ohne ihn zu
ersetzen. Tabellen-/Typografierekonstruktion, Vektorgrafiken und besondere
Annotationsfelder besitzen ausdrücklich benannte Grenzen; dies ist keine
vollständige Mac-Funktionsgleichheit.

Die Linux-Prozessaufsicht verwendet einen eigenen PID-/Netz-Namespace, gehaltene
Verzeichnis- und Prozessdeskriptoren und einen Lebensdauerkanal. Fehlende oder
gesperrte Namespaces führen zum Fehler; es gibt keinen unsicheren Fallback.
Ausgaben entstehen in einem privaten Bereich am Ziel und werden erst vollständig
atomar veröffentlicht. Zielkomponenten mit Symlinks werden derzeit abgewiesen.
Bei einem ausgetauschten Elternpfad bleibt ein vollständiges Ergebnis zur
Wiederherstellung erhalten; ein Erfolg für den inzwischen anderen Pfad wird
nicht gemeldet.

Die drei lokalen Paketformate sind unten beschrieben. Eine GTK-Vorschau ist optional; echte Desktopabnahme und vollständige Backendabnahme bleiben Teil des [Linux-Plans](LINUX-PORT.md). Die älteren
[Entscheidungsproben](linux-port/P03-FOLLOWUP.md) sind von der Produktintegration
und deren Prüfstand zu unterscheiden.

## Lokale CLI-Pakete

```sh
PMT_LINUX_BUILD_IMAGE=pmt-linux-builder ./release.sh --format all
```

Unter Linux erzeugt `release.sh` ausschließlich lokale Debian-, Arch- und
portable Tar-Pakete samt SHA-256-Dateien unter `.build/linux-packages`.
`--format deb|arch|tar` wählt ein Format; `--no-build` verwendet den vorhandenen
versionsgleichen Laufzeitbuild. Vorhandene Paketdateien werden nicht ersetzt.
Es wird nichts installiert, hochgeladen oder nach macOS `/Applications` kopiert.
Die nativen Paketmanager verwalten Installation und Entfernung; Benutzerdaten
liegen außerhalb des Paketbaums. Der Stand ist eine Entwicklungsvorschau,
keine öffentliche Veröffentlichung.

## Optionale lokale strukturierte OCR

Standard-OCR bleibt die Voreinstellung. Die optionale strukturierte Methode
verwendet eine separat geprüfte lokale Docling-/TableFormer-CPU-Runtime mit
mitgeliefertem CPython3.12; sie setzt keine passende Host-Python-ABI voraus.
Sie lädt während der Konvertierung weder Modelle noch Sprachdaten herunter.
Tesseract und die gewählten Sprachdaten bleiben lokale Distributionspakete.

Der lokale Installer erwartet eine bereits entpackte, extern geprüfte Quelle
und einen bestehenden privaten Produktlaufzeitordner. Er lädt nichts herunter,
entpackt keine Archive, installiert keine Hostpakete und ersetzt kein Ziel:

```sh
python3 scripts/install_linux_ocr_runtime.py \
  --source /absoluter/pfad/zur/geprueften-runtime \
  --runtime-directory /absoluter/pfad/zur/produktlaufzeit \
  --expected-manifest-sha256 cd4673de443d7e2570d6c4c4666cecb4924e2ceaf22703cba2a273a544eface6
```

Der Produktordner enthält `bin/poormans-text` und `lib`; der Installer ergänzt
`structured-ocr` direkt daneben. Sein Aufruferhash allein aktiviert keine neue
Runtime: der Swift-Kern akzeptiert ausschließlich seinen separat geprüften
festen Manifestpin. Er prüft vor Ausführung die vollständigen30192 Dateiinhalte.
Ein vorhandenes Ziel bleibt erhalten. Fehler behalten ausschließlich den eigenen
privaten Stage zur Inspektion; die Diagnose nennt dessen Basename.

Die Runtime benötigt etwa2.16GB zusätzlich. Basispakete schließen
`structured-ocr` ausdrücklich aus, auch wenn sie lokal bereits ergänzt wurde.
Es gibt hiermit keine öffentliche Modelldistribution oder Lizenzfreigabe.

```sh
./poormans-text --json --ocr-method structured --ocr-language en \
  --output /neues/ziel -- /pfad/scan.png
```

Fehlende oder veränderte Runtime führt zu69 ohne veröffentlichtes Ergebnis.
Die Methode ist eine Annäherung: erkannte Zeichen und Tabellen können vom
Original abweichen. Originalassets bleiben erhalten, Diagnosen benennen den
Einsatz und nötigenfalls den Standard-OCR-Fallback. Ein positives technisches
Ergebnis ist keine Inhaltsvollständigkeitsgarantie; die strenge automatische
Qualitätsauswertung bleibt getrennt.
