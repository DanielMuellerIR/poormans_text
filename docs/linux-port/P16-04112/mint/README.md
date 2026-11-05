# Finale Mint-Prüfung 0.41.12/build 97

2026-11-05, Linux Mint 22.2 (Zara), x86_64, Benutzer UID 1000. Geprüft wurde eine unveränderte relocierte vollständige Laufzeit ohne Swift-SDK und ohne Hostinstallation. Keine Host-GUI, kein Desktopfokus und keine Systemkonfiguration. Die alte 8791293d-Messreihe bleibt separat unverändert erhalten.

Snapshot: 45 reguläre Dateien, 174920160 Byte. Transportarchiv SHA256 `146e25b02c6c8a7677ecfe904e53913a6bc89b0d3d09b6e093c63ce706e8204b`. Alle 45 Dateihashes wurden lokal vor/nach Kopie und auf Mint vor/nach CLI und GTK geprüft, unverändert.

- CLI: `2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c`
- Produktions-GTK: `918a8d2bdd3658a92494a1e278d3ac6b1c241fa9536f5a3dbf9f63638998f2ed`
- Core- und UI-Guard: `cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520`

## Ergebnis

20 echte CLI-Fälle, 114/114 benannte Prüfungen erfüllt. Die 29 Katalogzeilen einschließlich Abhängigkeiten stimmen; CSV mit NFC/NFD sowie getrennten Groß-/Kleinschreibungsnamen, unabhängige XLSX-Zellen, Ausgabe-/Assethashes und 20 UTF-8-Quellzuordnungsgrenzen sind geprüft. PNG und ein-/zweibildrige HEIC erhalten die Originalbytes; drei Frame-Vorschauen einschließlich HEIC-Frame 2 stimmen bei Quellhash, PNG-Hash, Bytezahl, Auswahl und Dimensionen. Kein Tesseract/Pandoc/Swift; fehlende PDF-GI-Poppler/Cairo-Fähigkeit wird im Katalog und beim Vorschauaufruf korrekt offengelegt. Missing-DOCX/PDF/OCR ergeben Exit 69, OCR veröffentlicht nichts und meldet kein falsches „Applied“. Ungültige UTF-8-Bytes direkt im argv ergeben bewusst 64; ein echter ungültiger Verzeichnisentry ergibt getrennt 74. Vorhandenes Ziel: 73/alte Bytes unverändert. Symlink-Zieleltern: 74/kein fremdes Ergebnis. Quellen unverändert, nach jedem CLI-Fall keine eigenen lebenden Nachkommen.

Produktions-GTK mit nativer Mint-libgtk 4.14.5 ohne Swift-LD-Override im GUI-Prozess: echte AT-SPI-Convertaktion auf `Quelle ü.csv`, sichtbarer Status **Completed**, unveränderter Quellenhash und korrekte unabhängige Markdownmarker/Unicode. Quellenhash `c71d2c12a671843a308d39d4e5b55ceb2020aec2089772debc42dd7046fd8727`; Markdownhash `133ab1361b4eaa94838e21845e531ea884f1b861496243984e4990211335c71b`. Screenshot `gui.png` wurde visuell geprüft. Profile/Optionen kamen aus leerem eigenem HOME; kein bestehendes Profil. Der relative UI-CLI-Shim setzt die Swift-Bibliothekssuche ausschließlich für sein CLI-Kind.

Xvfb wählte die Displaynummer atomar über `-displayfd`; eigener Dbus sowie private PID-/Netz-/Mountnamensräume. Host-Homes, /run und /tmp waren abgeschirmt. System-Portaldienste wurden nur innerhalb der privaten Session gestartet; erwartete Warnungen zu nicht freigegebenem FUSE/Pipewire/Systembus stehen im Log. Diese Integrationen und Dateidialoge wurden nicht abgenommen. Der erste GUI-Testaufbau scheiterte vor Appstart am Mountziel /work auf schreibgeschütztem Root; der eigene Testpfad wurde unter das private /tmp verschoben. Der zweite Versuch bestand mit Exit 0 in 2,348 Sekunden. Kein Produktpatch war dafür nötig.

Keine Behauptung über frische Paketinstallation, vollständige GUI-Abnahme, neue Macparität oder OCR-Qualität. Zusätzliche GUI-Raster-/Clipboard-Fälle wurden in diesem begrenzten Auftrag nicht ausgeführt; die CLI-Rasterfälle sind enthalten.

## Kleine Reproduktion und Belege

`cli_probe.py` ist die tatsächlich ausgeführte 20-Fall-Probe mit festem CLI-Hash. In einen neuen privaten eigenen `/tmp`-Ordner gehören `runtime/`, beide Manifestdateien, `fixtures/`, `cli` und die Probes. Alle bereitgestellten Dokumente sind synthetisch; keine Downloads, Modelle oder Installation.

```sh
python3 cli_probe.py "$WORK"
python3 run_private_gui.py "$WORK"
```

`$WORK` absolut auflösen; die Probe verlangt neue Unterordner. Python mit pidfd-Unterstützung, bwrap, Xvfb/displayfd, dbus-run-session, AT-SPI-GI, xdotool und PIL.ImageGrab müssen bereits vorhanden sein. GTK/Gdk-GI-Typelibs werden nicht benötigt. `run_private_gui.py`/`private_session.py` enthalten dieselbe erfolgreich geprüfte Startfolge mit portabel aus dem Scriptpfad abgeleitetem Arbeitsverzeichnis; diese reine Pfadparametrisierung wurde lokal kompiliert, nicht als zusätzlicher Produktlauf gezählt. Die CLI-Probe prüft Hashes und Fehlerbedingungen im JSON; der Probeprozess selbst beendet sich nach dem Schreiben auch bei protokollierten Fehlern mit 0. Deshalb müssen `finished == true` und `failures == []` ausgewertet werden.

`evidence.json`: alle CLI-Fälle, Source-/Asset-/Outputhashes und portable `$WORK`-Pfade. PNG-Base64 wurde nach erfolgreicher Validierung weggelassen. `gui-evidence.json`: echte Aktion, Completed, Hashes, Screenshotbindung. `runtime-manifest.json`: vollständige Laufzeitidentität. `preflight.json`: vorhandene Mint-Werkzeuge. `first-*`: ehrlich erhaltener Testaufbaufehler. `private-gui.log`: erfolgreicher privater Lauf einschließlich Portalwarnungen.

Cleanup abgeschlossen 2026-11-05T05:17:49Z: eigene Remote-Prozesse beendet, 206 Dateien und 124 Verzeichnisse im eigenen Remote-/tmp-Baum nach gehaltenen Parent-/Root-FDs und Identitätsprüfung entfernt; kein Restprozess, Rootpfad fehlt. `cleanup.json` enthält den Nachweis. Große lokale Runtime-/Transport-/Rohkopien wurden entfernt; diese kleine Lieferung bleibt zur Übernahme erhalten.
