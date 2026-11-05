# HEIC-Proben wiederholen

Nur synthetische eigene Fixtures verwenden. `fixture.c` ist ein Testencoder,
kein Produktwerkzeug. `Dockerfile` erweitert die vorhandene Ubuntu-24-
Backend-Testbasis (`scripts/LinuxBackendTest.Dockerfile`) um Distro-libheif und
den ausschließlich für Fixtures erforderlichen x265-Encoder.

Im Container mit beschreibbarem eigenem Probeverzeichnis:

```sh
cc -Wall -Wextra -Werror fixture.c -o fixture -lheif
mkdir -p fixtures
./fixture fixtures/single.heic 1 1
./fixture fixtures/rotated.heic 1 6
./fixture fixtures/multi.heic 2 1
./fixture fixtures/too-many.heic 1001 1
python3 verify_probe.py --helper $REPO/Sources/PoorMansTextCore/LinuxBackends/heif.py --fixtures fixtures
python3 verify_negative.py --helper $REPO/Sources/PoorMansTextCore/LinuxBackends/heif.py --fixtures fixtures
```

`verify_probe.py` erzeugt auch die abgeschnittene Datei und PNG-Referenzen;
`verify_negative.py` erzeugt den veränderten ispe-Header. Beide laufen mit
Adressraumlimit. Das Encoderprogramm selbst verarbeitet nur erzeugte Pixel.

Für die echte CLI muss der erste Parameter ein Verzeichnis mit `fixtures/`
sein. Der zweite Parameter ist ein neuer Ausgabeordner, der dritte der explizite
CLI-Launcherpfad. Der Launcher setzt Swift-Laufzeitbibliotheken ausschließlich
für seinen CLI-Kindprozess. CLI und benachbarter PMT-Guard müssen zusammenpassen.

```sh
python3 verify_cli.py "$PROBE_ROOT" "$NEW_OUTPUT_ROOT" "$CLI"
```

Die Produktproben liefen in einem Container ohne Netzwerk mit unprivilegiertem
UID und erlaubten verschachtelten Namespaces (`--security-opt seccomp=unconfined
--security-opt systempaths=unconfined`); innerhalb davon verwendet die echte CLI
unverändert den mandatory bwrap-/Guard-ProcessRunner. Fehlendes Plugin wurde
mit read-only leerem tmpfs auf `/usr/lib/x86_64-linux-gnu/libheif/plugins`
geprüft, fehlende Bibliothek auf dem unveränderten Host. Keine fremden Homes,
Profile oder Quelldokumente mounten. Keine Paketinstallation auf dem Host.

`evidence.json` ist der kleine historische Testbeleg; die drei großen
1001-Frame-Fixture-/Buildkopien müssen nicht dauerhaft aufgehoben werden.
