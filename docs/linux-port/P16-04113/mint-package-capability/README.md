# Mint P15: begrenzte COW-Fähigkeitsprobe

Ergebnis: Eine sichere native COW-Installationsumgebung ist mit dieser begrenzten Probe **nicht belegt**. Kein Paket übertragen, kein dpkg/apt ausgeführt, keine Paketdatenbank erzeugt oder geändert, keine Installation/Downloads/Dienst-/Desktopaktivierung. Nach Rootentscheidung keine weiteren Remotejobs.

Host: Mint-Testhost, Kernel 7.0.0-42-generic; bubblewrap0.9.0, util-linux unshare2.39.3. Ein einfaches unshare mit eigenem User-/PID-/Net-/Mountnamespace endete0. Overlay ist in /proc/filesystems vorhanden. Hostlower wurde ausschließlich readonly eingeblendet; die einzige beabsichtigte schreibbare Hostbindung war die eigene zufällige /tmp-Wurzel. Home/root/run/tmp/dev/proc waren für den geplanten Innerlauf privat. Es wurde keine Hostsystem-Schreibprobe erreicht.

Drei kurze Anläufe, zwei davon reine Aufbaufehler: (1) /work war auf readonly Root kein anlegbarer Mountpunkt; (2) der verlegte Workdirparameter war falsch umgeschrieben. (3) Mit eigenem Mountpunkt innerhalb privatem /tmp und korrigiertem Workdir scheiterte das tatsächliche Overlay-/usr-Mount mit Exit32 und „cannot mount overlay read-only“. Deshalb wurden weder /usr-/var-Copy-up noch die geplanten privaten Schreibproben als erfolgreich behauptet. Diese Meldung beweist keine allgemeine Kernel-Unmöglichkeit; sie reicht hier nicht als sichere Grundlage für native Install-/Upgrade-/Remove-Tests. Kein weiterer Namespace-/Docker-/Rootansatz gestartet.

Vor und nach jedem Lauf identisch:

- /usr/bin/true: SHA256 8a63c98320173f79e263115e10cefc170155e47d1fd4b5a70e4429d2699cae28.
- /var/lib/dpkg/status: SHA256 b5a597bf504882666ea78de448e4683686f4e34616c747ed37e9b0e3894d12c8.
- Geplanter /var/tmp-Marker auf dem Host blieb abwesend.

Die ersten beiden eigenen Wurzeln wurden automatisch entfernt. Der Overlaykernel hinterließ im dritten eigenen Workbereich ein Verzeichnis mit Modus000; initiale rmtree-Bereinigung scheiterte daran. Der Baum wurde danach anhand des exakten eigenen inside.py-Hashes und UID identifiziert, ausschließlich eigene Verzeichnismodi ohne Symlinkfolge repariert und vollständig entfernt (cleanup.json). Keine Mounts/Namespaces/Prozesse blieben aus dem Probeprozess aktiv. Eigene Nutzdateien maximal etwa1,4KiB pro Versuch, keine große Kopie; deutlich unter150MiB.

## Vorhandene Optionals, nur lesend inventarisiert

- Pandoc: nicht im PATH.
- Tesseract: nicht im PATH, damit auch kein eng-Nachweis.
- LibreOffice/soffice: ausführbare Pfade vorhanden; nicht gestartet.
- Python gi/cairo/PIL/uno: Module per find_spec auffindbar; dies ist kein erfolgreicher Import-/Backendfunktionsnachweis.
- Poppler-Typelib: in den beiden Standard-Typelibverzeichnissen nicht gefunden.
- libheif: System-DSO1.17.6 vorhanden; HEVC-Plugin/Decode hier nicht qualifiziert.

Die kleinen historischen Probequellen, JSON-Ausgaben und Cleanupquelle sind erhalten. Sie sind Diagnosebelege, keine freigegebene Installationsinfrastruktur. Nächster Produktlauf erst nach Rootmeldung mit finalem Paket/Hash; temporär bereitgestelltes Pandoc wäre ausdrücklich per --pandoc einzubinden.
