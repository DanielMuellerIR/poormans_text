# P15: lokale Linux-CLI-Pakete

Stand: 2026-11-05, Version 0.41.9. Debian-, Arch- und portable Tar-Pakete sind
implementiert und lokal geprüft. Das ist der CLI-Anteil von P15, keine öffentliche
Veröffentlichung und noch kein fertiges GUI-/Desktoppaket.

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

Offen bleiben GUI-/Desktopinstallation, vollständige Arch-Abhängigkeitsabnahme,
Mint-Paketinstallation sowie die abschließende Distributions-/Lizenzprüfung vor
öffentlicher Weitergabe. Die bereits bestandene Laufzeitprüfung auf Mint ist
keine durchgeführte native Paketinstallation.
