# Finale Produktwiederholung 0.41.12

2026-11-05: bestanden. Eigenes neues, netzloses Docker-Testsystem aus dem bereits
qualifizierten Arch/Westonimage; keine Downloads, Hostinstallation oder Änderungen
an Produktquellen. Der Paketcache-/Distrostand ist der bestehende P15-Stand, kein
frischer Mirrorabruf. `artifacts.json` identifiziert beide vorhandenen Testimages.

`lifecycle.json` belegt regulär pacman -U 0.41.11 → 0.41.12 und pacman -R,
unveränderte Signaturpolicy/Abhängigkeitsauflösung, fehlenden Swift-SDK und UID1000.
Lokale Previewpakete verwenden die unveränderte Optional/TrustedOnly-LocalFilepolicy
und separat überprüfte SHA256; keine Behauptung einer PMT-Paketsignatur.

Echte Unicode-CSV vor/nach Upgrade, sechs HEIC-Konvertierungen (single/90°/2Frames,
je OCR off/on), Originalbytes/Quellhashes/PNG-Framezahlen, 15 Rasterfälle sowie
zwölf PDF-Fälle bestanden. Nur der verschlüsselte PDF-Fixturefall fehlt in dieser
Wiederholung: qpdf ist im Testimage nicht vorhanden. Der erste Harnesslauf brach
bei dessen Fixtureerzeugung vor dem Produktaufruf ab; anschließend wurde dieser
Fall ausdrücklich entfernt, der vollständige Paketablauf auf frischem Container
wiederholt und erfolgreich beendet. Kein Produktfehler daraus abgeleitet.

`wayland.png` zeigt die unveränderte Produktions-GUI mit Completed und dem
WAYLANDCSVMARKER/Grüße-Ergebnis; visuell geprüft. AT-SPI betätigte tatsächlich
Convert. Privater Weston 15/Pixman, GDK_BACKEND=wayland, kein DISPLAY, eigener
0700-Home/XDG/Sessionbus, reales Waylandprotokoll, native Westonaufnahme.
GUI und Compositor beendet/abgewartet. Keine Portal-, Clipboard-, DnD-, HiDPI-
oder echte Desktopabnahme daraus abgeleitet.

CLI-SHA256: 2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c

GUI-SHA256: 918a8d2bdd3658a92494a1e278d3ac6b1c241fa9536f5a3dbf9f63638998f2ed

Paket-SHA256: fe70d9b1b949eb311801dbb704f25804399f2ee0c06d86fd68ec4a4ee7acb591

## PMT → vorhandenes Fastra und frisches Wiederöffnen

Auch die bestehende P13-Probe wurde mit genau diesem eingefrorenen PMT-Artefakt
wiederholt. `p13/snapshot-inventory.json` bindet sämtliche 45 PMT- und 370 Fastra-
Datei-/Symlinkeinträge. Originale vor/nach Kopie und nach Test identisch;
`p13/runtime-stability.json` bestätigt das. Nur eigene vollständige Kopien wurden
gestartet. Keine Fastraänderung, kein Consumerneubau.

Produktions-PMT konvertierte das echte synthetische DOCX mit PNG/Tabelle/Unicode.
Der echte GIO-Button öffnete das Markdown über eine private desktop-Datei
(DBusActivatable=false) im neuen echten Fastra-ELF-PID. Der tatsächliche Editor-
Puffer wurde vollständig per Ctrl+A/C gelesen und gegen das gespeicherte Markdown
verglichen. Unicode und relativer Bildlink waren im selben Puffer vorhanden;
PNG-Assetbytes entsprachen der Quelle. `p13/first.png` ist visuell geprüft.

Beide Apps wurden beendet. Ein normaler Dateiargv-Neustart sowie zusätzlich ein
Neustart mit neuem privatem HOME/Display und nachweislich vorher leerer Clipboard
lieferten denselben vollständigen Editorinhalt. `p13/fresh-before-copy.png` zeigt
den frischen Editor sichtbar und wurde visuell geprüft. Die spätere automatische
Aufnahme nach Copy war schwarz und wird nicht als Bildbeleg verwendet; die
unabhängige vollständige Clipboard-/Hashprüfung war erfolgreich.

Fastra 1.158.0/366: ELF e83f7e59677a39db95f60a5b9501746a3a8df492b0fcd086f7fa356480e03582.
Das mitgelieferte Fastra-Manifest enthält eine source_sha256-Angabe; daraus wird
kein unabhängig bewiesener Gitcommit abgeleitet. Der Nachweis bindet Artefakte,
nicht einen selbst verifizierten Fastra-Quellbuild. Bildlink/Assetintegrität sind
belegt, keine separate Bildrenderprüfung im Consumer.

## Wiederholung und Aufräumen

Die beiliegenden Pythonproben sind Anpassungen der vorhandenen P15/P13-Harnesses.
`verify_lifecycle.py` im identifizierten Archimage als Containerroot mit eigenen
Paketkopien/HEIC-Fixtures aufrufen; er startet alle Produktarbeiten als UID1000.
Paket-, CLI- und GUIhashes sind absichtlich auf den eingefrorenen Lauf gepinnt.
Die P13-Skripte erwarten eigene pmt/fastra-Runtimekopien unter /probe, vorhandene
Ubuntu-Python3.12-GI/Pillow-Harnesstools unter /probe/tools und explizites vorhandenes
Pandoc unter /pandoc/pandoc. Vorhandenen P13-Reproablauf benutzen, keine Original-
Laufzeiten starten. GUI erhält ausdrücklich keinen Harness-/Swift-LD-Pfad.

`cleanup.json` und `p13/cleanup.json`: keine lebenden UID1000-Prozesse, nur Loopback.
Das PMT-Paket wurde entfernt; Benutzerdateien blieben hashgleich. Alle eigenen
Test-/Toolcontainer sowie Paket-/Laufzeit-/Profilkopien wurden nach Sicherung
dieser kleinen Belege entfernt. Bestehende Images/Originalartefakte bleiben.

## Ergänzung: verschlüsselter PDF-Fall

2026-11-05 zusätzlich bestanden: Das vorhandene Host-qpdf 12.4.2 erzeugte aus
beiliegendem synthetischem source.pdf ein AES256-verschlüsseltes Fixture. Kein
Installations-/Downloadschritt. Ein eigener neuer SDK-freier Archcontainer aus
identischem Image installierte ausschließlich das geprüfte finale 0.41.12-Paket
normal und führte genau dieses Fixture als UID1000/netzlos aus. Ergebnis:
Exit 65, ok=false, kein Ausgabeziel veröffentlicht, Quellhash unverändert.
`encrypted/encrypted-result.json` bindet Fehler-JSON und CLIhash; `fixture.json`
bindet Generator und Fixturehashes. Das Paket wurde regulär entfernt und der
Container danach gelöscht. Damit sind insgesamt 13 unterschiedliche PDF-Fälle
gegen den finalen 0.41.12-Artefaktstand belegt; die erste 12-Fall-Matrix und ihr
qpdf-Harnessabbruch bleiben unverändert nachvollziehbar.
