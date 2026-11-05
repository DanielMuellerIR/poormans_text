# P15: native Wayland-Probe der Produktions-GUI

Stand: 2026-11-05. Erster Durchstich bestanden: Das unveränderte GUI-Produktpaket
0.41.11 verbindet sich nativ mit einem privaten Weston-Headless-Compositor und
konvertiert eine echte Unicode-CSV über eine echte AT-SPI-Convert-Aktion bis
zum abgeschlossenen GUI-Zustand. `result.png` ist eine erfolgreiche native
Weston-Aufnahme; sie zeigt Completed sowie WAYLANDCSVMARKER/Grüße in der
Markdown-Vorschau und wurde visuell geprüft.

## Beleg und Grenze

UID 1000, eigener 0700-Home/TMP/XDG-Runtime/Wayland-Socket und eigener Sessionbus.
DISPLAY fehlt vollständig; GDK_BACKEND ist ausdrücklich wayland. Es gab keinen
Xvfb-/X11-Fallback und keine Bindung des Hostdesktops oder von Hostprofilen.
`client.log` belegt tatsächliche wl_display/get_registry/xdg_wm_base-Kommunikation
und den virtuellen Headless-Output. `weston.log` belegt den Pixmanrenderer;
das Clientlog zeigt Mesa-EGL-swrast. GTK erhält keinen Swift-Library-Pfad.
Die source-/output-SHA256 stammen aus den echten Dateien; Marker und Unicodewert
wurden unabhängig geprüft. Nach der Konvertierung wurde bis zur wieder aktiven
Convert-Schaltfläche gewartet. Das ist die Ergebnisempfangsbarriere der GUI;
der abgeschlossene sichtbare Zustand wurde zusätzlich im Bild geprüft.

Es wurden weder besondere GUI-Testfeatures noch ein neuer Konverter oder eine
Produktänderung verwendet. `result.json` bindet die tatsächlichen Paket-, CLI-,
GUI- und Screenshot-SHA256. Das geprüfte umask077-Archpaket hat SHA256
`be532ac71569eaf1d1e538813c9abf15376982efdcdaf491d0585262afb16260`;
CLI und GUI entsprechen dem bereits geprüften 0.41.11-Artefaktstand.

Die native Aufnahme lief mit dem vorhandenen `weston-screenshooter` über den
explizit zugelassenen Debugmodus des einzelnen privaten Compositors. Dieser
Debugmodus ist nur Probeeinrichtung und keine Produktempfehlung. Weston meldet
beim SIGTERM-Shutdown eine Layer-Finalisierungswarnung sowie einige fehlende
DND-Cursor. Beide Programme wurden abgewartet; nach Ende des privaten Sessionbus
gab es keine lebenden UID1000-Prozesse. Es wurden keine zusätzlichen Fälle oder
Workarounds zur Behebung dieser Weston-Meldungen entwickelt.

Nicht abgenommen: Portale/Dateidialoge, Clipboard, Drag-and-drop, fremde Apps,
verschiedene Compositoren, HiDPI und eine echte Desktopsitzung. Diese gezielte
native Wayland-Probe erweitert den X11-Nachweis; sie behauptet keine solche
Desktopparität und ändert die gemeinsam freigegebene reversible GTK4-Wahl nicht.

## Distroinstallation und Downloadgrenze

Basis war das vorbereitete lokale Arch-Image
`sha256:333a63abc2687d3c14a4e2e440f0f80e4e295a7db8b935623c8daaa8ba01f713`,
abgeleitet vom [offiziellen Arch-Dockerimage](https://hub.docker.com/_/archlinux)
mit amd64-Manifestdigest
`sha256:42217d5f09e11d3fe7ad3b309b7fde891d458464dab5d674e629073765610427`.
Zusätzlich wurde ausschließlich offizielles Weston 15.0.1-3 mit neun regulär
aufgelösten Distroabhängigkeiten installiert. Alle zehn Pakete sind in der
nativen Pacman-Datenbank als Signature-validiert belegt. `pacman -Syu` und die
unveränderte Required/TrustedOnly-Repositorypolicy blieben aktiv; keine
Dependency-/Signaturoverrides. Lokale PMT-Testpakete verwenden weiterhin die
unveränderte Default-LocalFileSigLevel Optional/TrustedOnly mit separat geprüftem
SHA256, ohne Behauptung einer kryptografischen PMT-Paketsignatur.

Die zusätzlichen Paketarchive einschließlich Signaturen umfassen 4.477.323
Bytes, zuzüglich kleiner Datenbank-/Protokolltransfers, deutlich unter 150 MiB.
Während Setupdownloads war nur der eigene Container am Netz. Vor der
PMT-Installation wurde seine Docker-Netzverbindung getrennt; während und nach
der Produktphase war ausschließlich Loopback vorhanden (`cleanup.json`). Die
eigentlichen Konverterprozesse nutzen zusätzlich unverändert ihren privaten
ProcessRunner-Netznamespace. Es gab keine Hostinstallation.

Die bestehende P15-Arch-Basis enthält entgegen der ursprünglichen Cacheaussage
noch 319.458.793 Bytes öffentliche Paketarchive: `pacman -Scc --noconfirm` hatte
die All-cache-Abfrage mit dem Default No beantwortet. Diese Basis blieb
unverändert. Das neue Wayland-Testimage löscht den sichtbaren Paketcache
ausdrücklich; alte Basisschichten werden dabei nicht neu geschrieben oder
gesquasht. Die gemessene Differenz zum vorhandenen Cache ist der obige kleine
Zusatzdownload. `dependencies.json` hält beide Werte getrennt fest.

## Reproduktion und Aufräumen

Lokales neues Testimage: `pmt-linux-wayland-test:20261105`, ImageID
`sha256:c7c5cf572d4eceb44472b05fc51c4cdc74cec6f929f048c8a06af876654bf189`.
Es enthält Weston und die Distroabhängigkeiten, keine PMT-Installation,
keinen Swift-SDK, keine ephemeren GPG-Geheimschlüssel und keinen sichtbaren
Paketcache. Das Image bleibt für die abschließende Wiederholung erhalten.
`Dockerfile` beschreibt die zusätzliche Installation aus der bekannten lokalen
Basis. Der Paket-/Dependencyzustand ist ein dokumentierter Arch-Rolling-Stand.

Einen neuen eigenen Container mit `--init --network none`, erlaubten
verschachtelten Namespaces und ausschließlich eigenem Proof-/Paketmount starten.
Das freigegebene Paket zunächst gegen seine SHA256-Datei prüfen und normal mit
`pacman -U --noconfirm` installieren. Danach:

```sh
setpriv --reuid=1000 --regid=1000 --clear-groups \
  env -i PATH=/usr/bin:/bin HOME=/home/pmtprobe LANG=C.UTF-8 \
  python3 -I /proof/delivery/verify_wayland.py --evidence /proof/delivery/result.json
```

Die Probe erzeugt ihr privates Profil und startet den Sessionbus selbst. Nach
Erfolg das eigene Paket regulär entfernen und den eigenen Container beenden.
Keine Hostdisplay-/Wayland-/DBus-Sockets mounten und keinen Swift-LD-Pfad an GTK
geben. Die Paketkopie und der ausgeführte Testcontainer werden nach dem Sichern
der kleinen Belege entfernt. Produktquellen und fremde Laufzeiten blieben unverändert.

Weston dokumentiert Headless als Testbackend und Pixman als CPU-Renderer in
seiner [offiziellen Laufzeitdokumentation](https://wayland.pages.freedesktop.org/weston/toc/running-weston.html).
Die tatsächlich verwendeten Optionen wurden zusätzlich mit der installierten
15.0.1-Hilfe geprüft.

Die erfolgreiche Datei-, Ordner- und Zielauswahl prüft zusätzlich
`../verify_portal_acceptance.py` mit der unveränderten installierten
Produktions-GUI. Der Lauf benötigt die Xvfb-, AT-SPI-, Pillow- und XTest-Werkzeuge
des privaten Testimages sowie den echten GTK-Portalbackend. Er startet seinen
eigenen Xvfb und Sessionbus mit leerer Umgebung und eigenen HOME-/XDG-Ordnern.
Die Xauthority muss innerhalb dieses privaten Testbaums liegen. Testfokus wird
zusätzlich an den Titel und die PID des Portalprozesses gebunden. Es werden
keine Eingaben an einen vorhandenen Benutzerdesktop gesendet.

```sh
python3 -I scripts/linux-probes/p15/verify_portal_acceptance.py \
  --evidence /eigener/pruefordner/portal.json
```

Zwei OpenFile- und zwei SaveFile-Aufrufe müssen tatsächlich zurückkehren. Der
Prüfer konvertiert sowohl die gewählte Unicode-Datei als auch den gewählten
Ordner in die jeweils im echten Dialog gewählten neuen Ziele. Quelldaten und
endgültige Markdown-Fingerprints werden geprüft. Die positive Probe gilt für
X11 im privaten Testdesktop; sie ersetzt keine KDE-/Cinnamon-Desktopabnahme.
