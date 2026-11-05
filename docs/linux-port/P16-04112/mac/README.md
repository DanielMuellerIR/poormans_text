# Native Mac-Regression0.41.12/build97

2026-11-05. Der freigegebene WIP-Quellsnapshot wurde nativ auf arm64 mit macOS26.7.2/Swift6.4.2 geprüft. Keine GUI aktiviert, kein Bundle gestartet, keine Installation, Notarisierung, Rosetta-Nutzung oder Änderung eines bestehenden Checkouts. SwiftPM-Artefakte wurden nur lesend in eigene temporäre Caches übernommen; HOME, TMPDIR, Modul-/SwiftPM-/Security-/Konfigurationspfade und Preferences waren isoliert.

Finale SourceTreeSHA256: `7859118b1d27a37de1b4e7f6b9f9143545daec11f1ce8ce6e6f87c568e3f91b3`,509 Dateien. Alle Dateihashes vor und nach dem Lauf geprüft. Native CLI: `9c8713cf6d8a3687f54a4fdceae7de59669da838d76a41f054a0a9e8b94ace0d`. Native App kompiliert, nicht gestartet: `0e427f623266fe6054447100c8fa999c3bf6a4e76af757b7334a472d0ea4ab01`.

Core-Resttarget1052 Tests,9 übersprungen,0 Fehler. Portabletarget15 Tests,0 Fehler. Vorher zusätzlich3 Portable-XML- und20 Core-EPUB-/DOCX-Tests grün. Die ursprüngliche DTD-Prüflücke auf macOS wurde durch Wiederherstellung von XMLDocument.dtd geschlossen. Ein danach sichtbar gewordener SIGTRAP war ein Lebensdauerfehler des temporären XMLParser-Delegates im neuen Test; der reine Testfix besteht den vollständigen Portable-Retest. Die drei Quellzustände sind in evidence.json getrennt.

Die unveränderte bekannte24-Task-OCRAsyncBridge-Blockade bleibt ausdrücklich außerhalb des grünen Restlaufs; kein neuer Baselineversuch wurde durchgeführt. Deshalb keine vollständige Mac-Suite- oder Releaseabnahme. Der vorhandene Baselinebeleg liegt im Projekt unter docs/linux-port/P05-INTEGRATION.md und p05-evidence/ocr-baseline.json.

Echte CLI-Proben: NFC-Dateinamen mit Leerzeichen, Umlauten, Akzent, Ampersand und Apostroph; CSV mit9 unabhängigen Zellen/9 gültigen UTF8-Mappings; DOCX mit sämtlichen unabhängigen OOXML-Textläufen und bytegleichem PNG. Quellen unverändert, Outputgrößen und SHA256 gegen Manifest geprüft. --preview-page und --preview-frame liefern auf Mac kontrolliert69/ok=false, kein künstliches PNG.

Repro: verify_cli.py arbeitet nur mit explizitem CLI-/Source-/neuemOutputpfad und den vorhandenen synthetischen DOCX-/PNG-Fixtures. mac_runner.py/mac_fix1.py/mac_fix2.py dokumentieren den tatsächlich ausgeführten historischen Ablauf; sie sind an die jeweiligen Archivhashes und die autorisierte Frist2026-11-05T06:00Z gebunden. Keine automatische Quellenbeschaffung und kein Installationsweg. Die erste Harness-Pfadannahme wurde transparent auf SwiftPMs --show-bin-path korrigiert.

cleanup.json belegt: private Mac-Kopie am2026-11-05T04:41:37Z über geprüfte gehaltene Verzeichnisdeskriptoren entfernt; davor keine übrigen eigenen Prozesse.10024 Dateien/2487 Verzeichnisse entfernt, keine breiten Prozesssignale. Eigene lokale Uploadarchive ebenfalls entfernt. Kleine Belege und Reproskripte bleiben erhalten.
