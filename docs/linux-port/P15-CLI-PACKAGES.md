# P15: lokale Linux-Pakete mit optionaler GTK-Oberfläche

Stand: 2026-11-05. Debian-, Arch- und portable Tar-Pakete sind lokal implementiert.
Seit 0.41.10 ergänzt `--with-gui` GTK und eine Desktopdatei; CLI-Pakete bleiben
unabhängig baubar. Dies ist keine öffentliche Veröffentlichung oder vollständige
Zielsystem-/Desktopabnahme.

`release.sh` verwendet unter Linux den vorhandenen Linux-Build und erzeugt alle
drei Formate samt SHA-256-Dateien. Der Packager hält die Build-Sperre während der
Laufzeitkopie, bindet das Ausgabe-Elternverzeichnis über Dateideskriptoren und
publiziert vollständige Dateien per Hardlink ohne Überschreiben. Vorhandene Ziele
ergeben Exit 73, Symlink-Eltern werden abgewiesen. Ein restriktives `umask 077`
verändert weder die öffentlichen Verzeichnisrechte noch die Ausführbarkeit.
Der private Bauordner bleibt geschützt.

Die Pakete enthalten CLI, Prozessguard, Swift-/XML-/ICU-/Bildlaufzeit,
Backendskripte und Lizenz-/Hinweisdateien. Der Launcher bleibt nach Verschieben
des vollständigen Paketbaums nutzbar. Pandoc, Bubblewrap und optionale
Python-/Poppler-/Pillow-/Tesseract-Pakete bleiben ausdrücklich deklarierte
Systemabhängigkeiten. Es gibt keine Downloads beim ersten Import.

## Ausgeführte Prüfung

- Alle drei unter `umask 077` gebauten Formate: Prüfsumme, Rechte, verschobener
  Unicodepfad, echte CSV-Konvertierung sowie Quell- und Ausgabedateihashes bestanden.
  Erneute Paketierung bei vorhandenen Dateien liefert 73 und erhält alle Bytes;
  ein Symlink-Ausgabeelternteil bleibt ohne neue Ausgabe.
- Debian: In einem entbehrlichen Ubuntu-24.04-Container ohne Swift-SDK und ohne
  Netzwerk 0.41.8 installiert, ein echtes Profil angelegt, auf 0.41.9 aktualisiert
  und das Paket entfernt. Konvertierungen liefen als UID 65534. Quellbytes und
  Benutzerprofil blieben nach Upgrade und Entfernung erhalten; Paketdateien wurden
  entfernt. Es fand keine Installation auf dem Host statt.
- Arch: Echte ALPM-Installation, Datenbank-/Dateiprüfung und Entfernung mit dem
  vorhandenen pacman in einer privaten Wurzel und Datenbank. Hostsystem read-only,
  Netzwerk gesperrt, Systemhooks maskiert und Scriptlets deaktiviert. Der verschobene
  Launcher konvertiert Unicode-CSV ohne Swift-SDK. Wegen ausdrücklich übersprungener
  Abhängigkeitsauflösung ist dies keine frische vollständige Arch-Chroot-Abnahme.

Reproduktion nach dem lokalen Paketbau:

```sh
python3 scripts/linux-probes/p15/verify_packages.py --packages .build/linux-packages --packager scripts/package_linux.sh
python3 scripts/linux-probes/p15/verify_arch_lifecycle.py --package .build/linux-packages/poormans-text-0.41.9-1-x86_64.pkg.tar.zst
```

Der Debian-Lifecycle-Prüfer darf ausschließlich im entbehrlichen Root-Container
laufen; er verweigert den normalen Hostaufruf. `scripts/LinuxPackageTest.Dockerfile`
erstellt dessen Umgebung. Alte/neue DEBs und Prüfer werden nur read-only eingebunden.
Kleine Ergebnisse stehen unter [P15-EVIDENCE](P15-EVIDENCE/packages.json).

Offen bleiben echte Desktopinstallation, Mint-Paketinstallation sowie die abschließende Distributions-/Lizenzprüfung vor
öffentlicher Weitergabe. Die bereits bestandene Laufzeitprüfung auf Mint ist
keine durchgeführte native Paketinstallation.

## GTK-Pakete 0.41.10

Alle drei unter `umask 077` gebauten GUI-Pakete bestehen dieselben Hash-, Modus-,
Verschiebe-/Unicode- und realen CSV-Prüfungen einschließlich Kollisionserhalt.
Alle ausgelieferten ELFs werden vor Paketierung auf maximal glibc 2.39 geprüft.
GUI und CLI besitzen getrennte Launcher; GTK erhält keine Swift-Library-Pfade.
Die Paketierung übernimmt sämtliche gelockten Rust-Crate-Lizenz-/Copyrighttexte
sowie Notices der tatsächlichen Builder-Toolchain. Die dynamischen GTK-/GNOME-
Systembibliotheken bleiben deklarierte externe Abhängigkeiten.

Die SDK-freie Ubuntu-24.04-Prüfung installiert 0.41.9, legt als unprivilegierter
Benutzer ein Profil an, aktualisiert auf das GUI-Paket 0.41.10 und entfernt dieses.
Quelle und Profil bleiben erhalten. Die echte Release-GUI wurde auf privatem Xvfb
mit Dateiöffnung, Maus-/Tastaturkonvertierung und visuell geprüfter Textvorschau
benutzt. Die tatsächliche Arch-ALPM-Dateitransaktion wurde auch für das GUI-Paket
wiederholt; die damalige Probe übersprang Abhängigkeiten. Die neue reguläre Abnahme folgt unten.
Kleine Belege liegen unter [P12-P14-EVIDENCE](P12-P14-EVIDENCE/packages.json).
Die entsprechenden GUI-/Systemgrenzen nennt der [GTK-Bericht](P12-P14-GUI.md).

## Frische reguläre Arch-Abnahme 0.41.11

Das offizielle Arch-Basisimage wurde per Digest gebunden und mit normalem
`pacman -Syu` sowie regulärer Abhängigkeitsauflösung vorbereitet. Alle 597
Distro-Pakete sind in der nativen Datenbank signaturvalidiert; die Default-
Policy blieb unverändert. Die lokalen PMT-Testpakete sind per SHA256 geprüft;
eine kryptografische PMT-Releasesignatur wird dadurch nicht behauptet. Das
Setup blieb mit rund 433 MiB Basis-/Paketarchiven unter seinem 1-GiB-Budget.

Im frischen Container ohne Swift-SDK und ohne Netz bestehen Installation von
0.41.10, echtes Upgrade auf 0.41.11 und Entfernung ohne `--nodeps`, deaktivierte
Hooks oder Signaturoverride. Die tatsächliche installierte CLI wird durch
SHA256 an den getesteten Releasebuild gebunden. UID1000 konvertiert Unicode-CSV
und sechs HEIC-Varianten mit OCR aus/an; Originalassets, Frames, Berichts- und
Quellhashes stimmen. Zusätzlich bestehen alle 13 PDF- und 15 Rasterfälle.

Die normale installierte Produktions-GUI läuft mit Distro-GTK unter privatem
Xvfb/D-Bus, ohne Swift-Library-Pfad im GTK-Prozess. Eine tatsächliche AT-SPI-
Convert-Aktion liefert Completed und die erwarteten Unicodewerte in der passiven
Markdownansicht. Der Screenshot ist visuell geprüft. Nach abschließender
Entfernung bleiben 44 Fixture-/Ausgabedateien unverändert; es gibt keine
übrigen UID1000-Testprozesse. Der eigene Container und seine Paketkopien sind
entfernt. [Kleine Belege](P15-EVIDENCE/fresh-arch/product-04111.json) und
Reproduktion unter `scripts/linux-probes/p15/fresh_arch/` bleiben erhalten.

Diese bestandene Produktionsprobe schließt die frühere Lücke der regulären
Arch-Abhängigkeiten. Sie ersetzt keine KDE-/Cinnamon-/Wayland-Desktopabnahme,
Mint-Paketinstallation oder öffentliche Distributionsfreigabe. Die drei
0.41.11-Paketformate bestehen auch erneut die [restriktiven Modus-, Verschiebe-
und Kollisionsproben](P15-EVIDENCE/packages-04111.json). Jedes ausgelieferte ELF
muss x86_64 und höchstens glibc 2.39 sein.
