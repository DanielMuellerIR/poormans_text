# Produktnachweise 0.41.14

Stand: 2026-11-05. Swift bleibt der gemeinsame Konvertierungskern, GTK4 der
reversible gemeinsame Linux-Toolkitentscheid. 0.41.14/build99 ergänzt den
passiven Rastervergleich um den vorhandenen Mac-Bedienumfang Fit/100 %/Zoom.
Das Swift-Konverterverhalten ist gegenüber dem [geprüften 0.41.13](../P16-04113/README.md)
unverändert; dort bestandene Backend-/Prozess-/Serienprüfungen behalten ihre
Artefakthashes und werden hier nicht als neue Läufe ausgegeben.

## Finale Artefakte und Prüfungen

Linux-CLI SHA256 `8abc9197eeced8df043d788e349acb553bd86dd81546a6fda1faf15a93bac0cb`;
GTK SHA256 `85e70bf0654f4b308a5db2d483eaf258dd376f83773703febe23fa91d05ddcf2`;
Guard weiterhin `cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520`.
Die Root-Quelldifferenz im Swift-Produktbereich gegenüber 0.41.13 ist ausschließlich
`ProductInfo.version`; neue UI-Logik bleibt im dünnen Rust-/GTK-Adapter.

| Nachweis | Tatsächliches Ergebnis und Grenze |
| --- | --- |
| [Produktions-Zoom](zoom-production/README.md) | Regulärer Build ohne Selftestfeatures: echte Maus-/Tastaturwahl OCR Off und Bericht, Convert→Completed, Compare source,100 %,400 %,Scroll,Fit und normales Schließen. Quelle/Originalasset bytegleich; alle 31 überwachten Runtimehashes gleich. Privates SDK-freies Noble/Xvfb, tatsächliche MesaGLX/Gallium/LLVM-Ladung, keine AT-SPI-/Screenreader- oder echte Desktopabnahme. |
| [Zoom-Kandidat](zoom-candidate/README.md) | Derselbe SourceCanvas-/Raster-/Main-Quellhash mit Selftestfeature und.13-Core: fünf echte GUI-Zustände, 1×/2×, 700 px/Resize, beide Scrollenden, frühe/späte Verifikationsablehnung.100 % = 1024×768 logical, 400 % = 4096×3072; keine neuen Backendjobs. Quell-FD 1→0 und WeakWindow/Canvas/Texture frei. Nicht mit Produktionshash verwechselt. |
| [Rust-Units](rust-units.log.gz) | 35 GTK- und 3 Bridge-Units, 0 Fehler. Ein interner Hilfslauf wird nicht zusätzlich gezählt; 18 Host-/Hilfstesteinstiege standardmäßig ignoriert, keine neue Hosttestabnahme daraus. |
| [Clippy](clippy.log.gz) | Workspace, alle Targets/Features,`-D warnings` bestanden. |
| [Alter Consumer → aktueller Producer](consumer-compatibility/README.md) | Exakt früherer echter Treiber ebb3feac… besteht CSV und MBOX gegen0.41.14:29 Formate, korrekter Einstieg/index.md, Vorbereitung/Adoption und unveränderte Quellen. Kein neuer Import-GUI-/Commit-/PNGasset-/Kollisionsnachweis. |
| [Drei Pakete](packages.json) | Debian/Arch/portablesTar unter umask 077: korrekte öffentliche Dateimodi, relocierte Unicode-CSV und Hashes; Kollision 73 erhält alle Pakete, Symlinkeltern ohne Ausgabe. Keine neue native Paketinstallation behauptet. |
| [Nativer Mac](mac/README.md) | 337 ausgewählte Build-/Testdateien nativ arm64: CLI/AppExecutable gebaut, einzeln lipo-verify; CLI 0.41.14, genau 5 ProductInfoTests/0 Skips/0 Fehler einschließlich CFBundle 99. App nicht gestartet/installiert, keine Rosetta-/globaleCLI-Nutzung. Keine Wiederholung der bekannten OCR-Stallsuite. |
| [Nativer Mint-DOC](mint-doc/README.md) | Finales .14-Paket privat extrahiert, echtes vorhandenes LO 24.2.7.2/UNO mit ausdrücklich privatem Pandoc. Normaler DOC und RichAutoOpen-DOC erfolgreich: unabhängige Texte/Listenmarker, Legacywarnung, SourceIdentity/Report/Outputmanifest und Original-PNG bytegleich. MacroNever/NoUpdate, keine neue unsichere Makro-Positivkontrolle. |
| [Nativer Mint-PDF, 0.41.13](mint-pdf-013/README.md) | Zusätzlicher gezielter Nachweis am früheren 26470eaf…-CLI: 12/12 Fälle, sieben digitale OCR-off-Konvertierungen, drei 65-Fehler, echtes Missing-Tesseract 69 ohne Publikation und Seite-2-PNG-Vorschau. Inhalt/Bildpixel/Links/Annotationen/Seitenwahl/Metadaten/Hashes stimmen. Nur passende 26.266-Byte-Typelib privat ergänzt und RO eingebunden; keine Hostinstallation oder native OCR-Qualitätsbehauptung. |

Die Mac-Restregression 0.41.12 mit 1052 Core- und 15 Portable-Fällen bleibt der
Nachweis der vorherigen gemeinsamen Logikänderungen. Ihre bekannte unveränderte
24-Task-OCRAsyncBridge-Blockade ist weiterhin ausgespart und verhindert eine
uneingeschränkte Gesamtregressionsaussage. Die Versionstests hier ersetzen
keine vollständige Mac-Suite oder Release-/Universal-/Notarisierungsabnahme.

## Einordnung und nächste Freigaben

Die Entwicklungsvorschau enthält Swift-Laufzeitpaketierung, sichere Linux-
Prozess-/Dateiadapter, PDF, Standard-OCR, Raster/optionales HEIC, statische RTFD-
Anhänge und sicheres DOC/UNO sowie GTK, Profile, versiegelte Clipboardquellen,
passive Vorschau/Quellvergleich und lokale Pakete. Die früheren realen ext4-
ENOSPC-, Zielverzeichnistausch- und 17 Runnerverlustnachweise bleiben erhalten;
Zoom verändert diese Schutzgrenzen nicht.

**Keine vollständige Linux- oder öffentliche Distributionsfreigabe.**
P11 besitzt mit [Docling/TableFormer](../P11-DOCLING.md) einen teilgeprüften
Kandidaten, aber noch keinen sicheren Produktadapter oder ausreichend breiten
Qualitätskorpus. Strukturierte OCR bleibt unavailable. Echte KDE-/Cinnamon-
Bedienung/Portale/Drop/Clipboard, vollständige Format-/Consumer-Matrix, native
Mint-Paketinstallation und abschließende Distribution bleiben eigene Tore.
Der begrenzte Mint-COW-Versuch ist kein Installationsnachweis. Auch die neuen
privaten Paketextraktionen werden ausdrücklich nicht so bezeichnet.

Fastra ist ausschließlich lesend geprüft. Der echte .12-Editoröffnungs-/Reopenlauf
bleibt erfolgreich; ein vollständig gebundenes aktuelles Consumerartefakt mit
Importdialog ist für die übrige P13-Matrix noch nötig. Die Consumerkorrekturen
bleiben beim Fastra-Chat, keine Fastra-Quelländerung durch diesen Auftrag.
Originalrechteck-Overlays gehören auch nicht zum nativen Mac-Vertrag; sie sind
keine zusätzlich erfundene Portierungsfreigabeanforderung.

## Reproduktion und Cleanup

Die Unterberichte enthalten kleine synthetische Fixtures, echte Berichte,
Quell-/Artefaktmanifeste, Laufskripte, Screenshots und Cleanupbelege. Komprimierte
Rohlogs bleiben entpackt bytegleich; ursprüngliche Liefermanifeste beziehen sich
auf die unkomprimierten Dateien. Private Kompilierpfade wurden nur in den
zusammengefassten Rustlogs zu `$REPO` neutralisiert. Herkunftsmanifeste benennen
auch nicht duplizierte temporäre Hilfsdateien; keine Runtime/SDK-/Modellkopie
wurde in diesen Beleg aufgenommen.

Alle eigenen Mac-/Mint-Remote-Testbäume und Prozesse sowie die einzelnen GUI-
Testcontainer sind nach Sicherung der Belege entfernt. Hostprofil-/Systemdatei-
Hashes blieben gleich, der Benutzerdesktop wurde nicht benutzt. Die eigenen
lokalen Zwischenstände werden nach dem gesicherten Meilenstein bereinigt;
abschließender Cleanupbeleg folgt im selben Verzeichnis. Kleine offene
Fehlerbelege behalten ihren Zweck und das Prüfdatum.
