# Linux-Produktprüfung 0.41.18

Stand 2026-11-05. Die ursprüngliche bwrap-Setupdiagnose bleibt jetzt auch bei
fehlgeschlagener PIDFD-Bindung vor dem CLI-Start in der GTK-GUI sichtbar.
Startgate und Prozessschutz bleiben verpflichtend. Swift bleibt der gemeinsame
Konvertierungskern; der aktuelle Fastra-Vertrag ändert sich nicht.

## Bestandene aktuelle Produktproben

- [GTK-/Bridge-Tests](gtk-units.log.gz): 40 GUI- und vier Bridge-Unit-Tests
  bestanden, darunter die neue Fehlerdiagnose mit ausdrücklich ausbleibendem
  Start-ACK. Die 18 markierten Umgebungshilfen sind getrennt behandelt.
- [16 echte Namespaceprüfungen](bridge-namespaces.log.gz) bestanden:
  Abbruch, Runnerverlust, fehlgeschlagenes PIDFD-Binden, gebundene Inputs,
  Startgate und Beendigung losgelöster Nachkommen. Zwei interne Hilfsprozesse
  werden von ihren Elternprüfungen gestartet. [Bridge-Clippy](bridge-clippy.log.gz)
  meldet keine Warnung.
- [Vier aktuelle Pakete](packages.json): DEB, Arch, Tar-Zstandard und ZIP
  entpackt und verschoben; tatsächliche Unicode-CSV-Konvertierung, Quellschutz,
  Ausgabefingerprints, Rechte, Kollisionen und Symlinkeltern geprüft.
- [Reguläre Paketmanager](installers.json): Die neuen Installer installieren
  die tatsächlichen .18-Pakete über apt auf Ubuntu und pacman auf Arch, starten
  die CLI als normalen Benutzer und entfernen das Paket regulär. Alle Schritte
  laufen in eigenen netzlosen Containern ohne Swift-SDK; keine Hostinstallation.
- [Wayland](wayland.json): Aktuelle Produktions-GUI mit privatem Weston,
  echter AT-SPI-Konvertierung und unverändertem Unicode-CSV-Original. Drei echte
  Portaldialoge geöffnet und abgebrochen: Dateien, Ordner, neues Ziel. Der
  [private DBus-Beleg](portal.log) enthält zweimal OpenFile und einmal SaveFile.
  Ergebnis bleibt durch Abbruch unverändert. [Aufnahme](wayland.png) visuell geprüft.
- [X11-Aufnahme](x11.png): dieselbe aktuelle Produktions-GUI konvertiert über
  echte AT-SPI-Aktion unter eigenem Xvfb/Sessionbus; Ergebnis und Quelle geprüft.
- [Gezielter Fehlerfall](sandbox-error.json): Maskiertes Container-/proc
  verhindert den Namespace-Start. Die CLI bleibt gesperrt, zugleich ist die
  [ursprüngliche Mountfehlermeldung](sandbox-error.txt) in der echten GUI sichtbar.
  Die positive Gegenprobe verwendet ausschließlich im Testcontainer erlaubte
  verschachtelte Namespaces. Keine Produktsicherung wurde abgeschaltet.

CLI, Guard, GUI und Schema sind in [artifacts.json](artifacts.json) gebunden.
Die Container-Proben verwenden keine Hostdisplay-, Host-DBus- oder
Host-Wayland-Sockets. Die GUI nutzt die Bibliotheken der jeweiligen Distribution.

## Ergänzte Prüfwerkzeuge

Die erweiterten instrumentierten GTK-Prüfungen bestehen ebenfalls:
[Start, zweite Instanz und Abbruch](gui-selftest.json) sowie
[neun Clipboardkodierungen, versiegelte Originalbytes, echte Konvertierung,
Kopieren, Freigabebarrieren und Profile](gui-p14.json). Der Testbau verwendet
unveränderte .18-Rust-Produktquellen mit zusätzlichem ui-self-test-Feature;
er ersetzt nicht die oben getrennt nachgewiesene Produktions-GUI.

Zwei veraltete Prüfer wurden korrigiert: Der Startprüfer wartet begrenzt auf das
Ende des asynchronen Formatkatalogs statt nur eine Sekunde. Der P14-Prüfer liefert
nun auch das echte HEIC-Fixture, verlangt neun erfolgreich erhaltene Kodierungen
und prüft die inzwischen implementierte versiegelte Speicherquelle anstelle
entfernter Temporärdateien. Es wurde kein Formatfall ausgelassen.

Die [aktuelle RTFD-Matrix](rtfd-summary.json) besteht einschließlich statischer
HEIC-Anhänge, Originalbytes und kontrollierter Mehrbildablehnung auf Arch.

## Qualität und Grenzen

Die [vollständig wiederholte Qualitätsmatrix](quality.json) besteht die zehn
Formatfamilien, 15 Raster-/OCR-Fälle und 13 PDF-Fälle. Die alten Proben werden
nun ausdrücklich für vorhandene oder fehlende strukturierte Modellruntime
aufgerufen; beide Konfigurationen wurden tatsächlich geprüft. Ein ausdrücklich
angeforderter vorhandener Backend darf dabei nicht still als Skip verschwinden.
Die PDF-Sollzählung grenzt den Originalseiteninhalt vom zusätzlichen Linklabel ab.

Die strenge Inhaltsfreigabe bleibt FAIL: fünf von acht synthetischen Zelltexten
stimmen exakt; natürliche Diagramm-/Textverluste und Tabellenstruktur fehlen
weiterhin. Referenzdaten und Qualitätsgrenzen wurden nicht gelockert. Laufende
alternative OCR-Proben sind keine bereits integrierte Produktkorrektur.

Echte Desktopbedienung, erfolgreich abgeschlossene Portal-Dateiauswahl,
Clipboard-/Drag-and-drop-Zusammenspiel und die vollständige Zielsystem-/HiDPI-
Matrix bleiben von diesen bestandenen isolierten Proben getrennt. Die öffentliche
Modell-/Lizenzverteilungsfreigabe bleibt ebenfalls separat.

Seit dem nativen Mac-Gesamtlauf .17 unterscheidet sich unter Sources/Tests nur
ProductInfo.swift durch die Versionsnummer. Der .18-Funktionsfix betrifft die
Linux-Rust-Bridge; eine neue native Mac-Gesamtregression wird nicht behauptet.

## Reproduktion der Containergrenze

Ein nicht privilegierter verschachtelter bwrap-Lauf benötigt in dieser
Testumgebung einen eigenen procfs-Mount. Docker-Maskierungen können ihn sperren.
Die [offizielle BuildKit-Dokumentation](https://github.com/moby/buildkit/blob/master/docs/rootless.md#docker)
beschreibt dafür die gezielten Containeroptionen seccomp=unconfined,
apparmor=unconfined und systempaths=unconfined. Das sind Optionen der eigenen
isolierten Prüfcontainer, keine Empfehlung, Host-Sicherheitsregeln abzuschalten.
