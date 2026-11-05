# Kontrollierte Linux-OCR-Fehlerpfade

Finale CLI 0.41.12, SHA256 `2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c`. Elf echte CLI-Läufe im vorhandenen SDK-freien Noblebackendimage bestehen. Alle Quellhashes bleiben gleich; acht erwartete Fehler veröffentlichen keinen Zielordner. Keine Rootquelle, Hostwerkzeuge, GUI oder Modelle wurden verändert.

| Kontrollierter Containerzustand | PNG / PDF mit OCR | Veröffentlichung |
| --- | --- | --- |
| Nicht ausführbare Tesseract-Maske | jeweils 69 | keine |
| Erfolgreiches --list-langs, aber null installierte Sprachen | jeweils 69 | keine |
| --list-langs meldet eng; Erkennung stderr IOFaultMarker und Exit2 | jeweils 74, Marker im Corefehler | keine |
| --list-langs schnell; Erkennung sleep5, --timeout0.5 | jeweils 124 | keine |
| Nicht ausführbares Tool, OCR ausdrücklich off | jeweils 0 | erwartete Ausgabe |
| Echtes unverändertes Tesseract, weißes PNG | 0 | Originalbildasset bytegleich |

Der echte Blanklauf meldet `ocr.languageDefault` und `image.textUnavailable`, kein `image.ocrApplied`. Keine zusätzliche synthetische Empty-TSV-Probe war erforderlich. Die acht negativen Zustände sind ausdrücklich kontrollierte Toolmasken und keine Behauptung eines realen Tesseract-Defekts.

Die generische Timeoutdiagnose nennt kein Tool. Deshalb beobachtet die Probe ausschließlich lesend innerhalb des privaten Container-PID-Namespace, dass der kontrollierte `/bin/sleep 5` tatsächlich ein Nachkomme des jeweiligen CLI-Prozesses ist. Beide Erkennungszweige wurden beobachtet; damit wird kein früher Raster-/PDF-Helpertimeout fälschlich als OCR-Erkennungstimeout gewertet. Gesamtzeiten einschließlich Vorbereitung: etwa1,12s PNG und1,41s PDF.

## Reproduktion

Das kleine Archiv enthält Probescript, kontrollierte Ersatzdateien mit ihren originalen Ausführungsrechten, synthetische Fixtures, JSON-Receipts und Hashmanifest. `reproduce.sh` verlangt ein bereits vorhandenes lokales Image und setzt ausdrücklich --pull never/--network none. Ersatzdateien werden ausschließlich für den einzelnen wegwerfbaren Container readonly über `/usr/bin/tesseract` gebunden. Echte Tesseract-Dateien/Sprachdaten bleiben im Image unverändert. Die Fixtures sind zusätzlich readonly eingeblendet; eigene Ausgaben liegen ausschließlich im Probenvolume. Alle Läufe als UID1000 mit den bestehenden, für innere bwrap-Namespaces nötigen Containerflags.

Nach dem Entpacken die exakt gehashte CLI mit Ressourcen und Guard aus dem passenden Runtimeartefakt in `runtime/` kopieren; `runtime/cli` ist bereits enthalten und setzt Swift-LD nur für das CLI-Kind. Beispiel: `cp -a "$PMT_OCR_RUNTIME/bin/." ./runtime/`, dann `PMT_OCR_RUNTIME=/path/to/runtime ./reproduce.sh`. Der Scriptstart lehnt eine andere CLI-SHA ab. Runtimebibliotheken und Ressourcen sind im Manifest separat gehasht. Historische Runtimes und Bilder sind nicht Bestandteil des kleinen Belegs.

Snapshot und entbehrliche große Laufkopien werden nach der Belegsicherung entfernt; die kleine Reproduktion bleibt erhalten. Alle eigenen Container waren mit --rm versehen und sind beendet. Die produktiven Quellen, Hostruntime und Host-Tesseract wurden ausschließlich gelesen.

## Echter Missing-Tool-Unit

Zusätzlich wurde `PoorMansTextLinuxTests.LinuxOCRTests/testMissingOCRBackendCannotPublishAnImageResult` im selben SDK-freien Noble-/Missing-Tesseract-Namespace wirklich ausgeführt: **1 Test, 0 Fehler, 0 Skips**, 0,312s. Der Test prüft DocumentConverter-Fehlertyp, ausbleibende Veröffentlichung und unveränderte eigene 32×24-PNG-Fixture. Debugverzeichnis mit Geschwister-Ressourcen und Testlaufzeitbibliotheken wurden vollständig readonly eingeblendet; LD_LIBRARY_PATH nur im Testkind gesetzt. Keine Vollsuite im manipulierten Namespace. `reproduce_unit.sh` verlangt die bestehenden Debug-/Libpfade ausdrücklich. Ein Python-Elternprozess vermeidet den bekannten Sonderfall des direkten Swift-Testprozesses als Container-PID1.
