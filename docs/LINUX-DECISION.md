# Entscheidung nach P00–P04

Stand: 2026-11-04. Basis: PMT `17328f17d63843025b33b45a87fa3d13db5e11d7`
(Produkt 0.41.7), Fastra `55ca70579861954a21cfbd22d96e12059fec68db`
(Produkt 1.157.1). Untersucht wurden isolierte Proben, keine produktive
Target-Auftrennung. **P05 wurde nicht begonnen. Ein vollständiger Rust-Neubau
ist durch die Befunde nicht begründet.**

Die Empfehlung ist, den vorhandenen Swift-Kern weiterzuverwenden. Der reale
Linux-Durchstich und seine Laufzeitlieferung funktionieren. Die verbleibenden
Sicherheits- und Backendprobleme müssen unabhängig von der Kernsprache gelöst
werden. Eine vollständige Linux-Version ist noch nicht freigegeben.

| Paket | Ergebnis | Abnahmegrenze |
| --- | --- | --- |
| [P00 Referenz](linux-port/P00-BASELINE.md) | Alle 29 Katalogformate und Querschnittsfähigkeiten zugeordnet; sieben reale Mac-Konvertierungen unabhängig geprüft | Kleiner Referenzkorpus; vorhandenes Mac-Binary durch Version/Hash identifiziert, Zuordnung zum Quellcommit ohne neues Buildmanifest offen |
| [P01 Vertrag](linux-port/P01-CONTRACT.md) | Echte Producer-Goldens und Original-Fastra-Consumer geprüft; 33 Beobachtungschecks | Reeller falscher Sammlungspfad; echte App-zu-App-/Tabwechsel-/vollständige Baumabnahme offen; daher nicht vollständig abgenommen |
| [P02 Swift/Laufzeit](linux-port/P02-SWIFT.md) | **Machbarkeit bestanden:** fünf Formate auf beiden Zielsystemen ohne Swift-SDK | Separater CLI-Harness, ausgewählte Adapter; keine Freigabe des vollständigen Produkt-CLI-Vertrags oder der ausgeschlossenen Backends |
| [P03 Sicherheit](linux-port/P03-SAFETY.md) | Kernelprimitive und normaler Runner-Abbruch funktionieren; Besitzerverlust reproduziert | **Nicht bestanden:** Werkzeug überlebt harten Runnerverlust; ext4, echter voller Datenträger und Produkt-End-to-End fehlen |
| [P04 Backends](linux-port/P04-BACKENDS.md) | Reale Linux-Proben mit gepaartem Mac-Vergleich | **Nicht bestanden:** RTFD-Bilder, HEIC und strukturierte OCR offen; Makro-Ereignistest fehlt |

## Swift und Laufzeitpaketierung

Ein Ubuntu-24.04-Build mit Swift 6.2.1 konvertiert CSV, XLSX, IPYNB, DOCX mit
PNG und RTF. Dasselbe Binary läuft mit seinen mitgelieferten Bibliotheken auf
CachyOS und Mint 22.2 ohne installierte Swift-Entwicklungsumgebung. Alle fünf
Formate bestehen auf beiden Systemen unabhängige Textzählungen und Quellhash-
prüfungen; das DOCX-Bild bleibt byteidentisch. Build und Konvertierung laufen
nach dem Dependency-Setup offline.

FoundationXML braucht explizite Imports für Parser und DOM. Regex und die
geprüfte CoreFoundation-Encodinggrenze funktionieren. Hashing verwendet
gepinntes swift-crypto statt eigener Kryptografie; zlib ist explizit angebunden.
Darwin-Aufrufe, off_t und autoreleasepool brauchen begrenzte Anpassungen. Die
Probe deaktiviert den nicht portablen mmap-Mounttest zugunsten des vorhandenen
Lesewegs. Der reproduzierbare Patch liegt getrennt vom Produktcode.

Nur Swift-Bibliotheken mitzuliefern genügte auf CachyOS nicht: Noble-libxml2 und
ICU74 müssen ebenfalls berücksichtigt werden. Das Probe-Paket enthält außerdem
Pandoc, seine Bibliotheken und Datendateien. Diese dynamische Richtung ist
praktisch belegt. Vor Distribution fehlen Release-Build, Loader/RPATH-Konzept,
Lizenz-/Quellangebotspflichten und Sicherheitsupdates für mitgelieferte
Bibliotheken. Das statische SDK muss diesen belegten Weg nicht ersetzen.

Der Restaufwand ist die saubere produktive Trennung dieser bereits erkannten
Grenzen sowie die Integration der separat geprüften Backends. Ein lauffähiger
Fünfformat-Harness ist keine Aufwandsschätzung für sämtliche 29 Katalogformate.
Es gibt keinen Anlass, die vorhandenen Parser vorsorglich in Rust neu zu schreiben.

## Sichere Prozesse und Veröffentlichung

`renameat2(RENAME_NOREPLACE)` besteht auf Btrfs und tmpfs einen Versuch mit 64
konkurrierenden Veröffentlichungen. Ein bestehendes Ziel und ein Ziel-Symlink
bleiben erhalten. Gehaltener Quelldeskriptor, FIFO-/Symlinkabwehr, Rechtefehler
und der EXDEV-Fehler über Dateisystemgrenzen sind belegt. ENOSPC wurde nur mit
`/dev/full` geprüft; beide erreichbaren Zielsysteme verwenden Btrfs.

Der tatsächliche Swift-ProcessRunner mit ausschließlich ersetztem Systemimport
besteht Timeout, Abbruch, wörtlichen Argumenttransport, Ausgabegrenze und
Capture-Cleanup. Die Prozessgruppe überlebt jedoch einen harten Verlust des
Runners. Vor sicherem Produktbetrieb braucht es eine kontrollierte Bindung des
gesamten Prozessbaums an den Auftrag. Eine Gruppen-ID allein reicht nicht.
Die Produktveröffentlichung benötigt eine ausdrückliche atomare No-Replace-
Operation und gebundene Zielverzeichnisse; die bestehende Vorprüfung allein ist
keine Linux-Freigabe. Auf nicht belegten Wechsel-/Netzlaufwerken muss sie
verständlich scheitern. Diese Arbeit wurde nicht als P05 vorgezogen.

## Backendentscheidungen

| Fähigkeit | Empfehlung aus den Proben | Noch erforderlich |
| --- | --- | --- |
| PDF | Poppler weiterverwenden; kein belegter Anlass für einen PDFium-Vergleich | Lesereihenfolge/Koordinaten normalisieren; gemischtes PDF sicher zusammenführen; größeres Qualitätskorpus und Lizenz-/Bindungsentscheidung |
| Standard-OCR | Tesseract mit ausdrücklich installierten Sprachdaten weiterprüfen | Sprachcode-Abbildung, Rotation/Qualität und Digitaltext-Merge; Umlautabweichungen sichtbar machen |
| Bilder | Metadaten vor Decodierung und begrenzte Frames erhalten; Pillow dient nur als Prüfharness | Produktdecoder wählen, Grenzen/Orientierung/Frames abnehmen; HEIC einschließlich tatsächlicher Codec-Laufzeit prüfen |
| DOC | LibreOffice als isolierten externen Prozess weiterprüfen | Semantische Listen, unabhängige DOC-Dateien, ausführbarer Makro-Ereignistest, kontrollierte Nachbearbeitung externer Verweise |
| RTFD | Vorhandene RTF-/Paketlogik mit sicherer lokaler Assetauflösung weiterführen | LibreOffice allein verliert NeXTGraphic-Bilder; Paket-/Bildpfad ohne AppKit entwickeln |
| Strukturierte OCR | **Kein gleichwertiger Ersatz nachgewiesen** | Lokales Layout-/Tabellenbackend mit demselben Korpus prüfen oder Teilumfang ausdrücklich beschließen; P11 bleibt offen |

LibreOffice lief mit eigenem Profil, gesperrten Makroeinstellungen, Netz-/PID-
Namespace und Zeitlimit. Die Netzsperre ist tatsächlich nachgewiesen; eine
Remote-Bild-URL bleibt aber im exportierten HTML erhalten. Ein späterer Adapter
muss sie entfernen oder diagnostizieren. Die Konfiguration allein ersetzt keinen
positiv kontrollierten Makro-Ereignistest. Keine Backendbibliothek wird durch
diese Versuche zur Distribution freigegeben.

Im strukturierten Korpus liefert der Mac eine dreispaltige Markdown-Tabelle
samt Diagnose für verbundene Zellen. Tesseract liefert Text und Geometrie,
mischt Textspalten und bietet keine gleichwertige Tabellen-/Zellsemantik.
Ein Rust-Neubau würde diese fehlende Erkennung nicht beseitigen.

## Fastra und nächste Entscheidungen

Der Vertrag bleibt unverändert kompatibel; es gibt keine neue Protokollversion.
Reale Sammlungen führen ihre Unterdokumente auch in `assets`. Fastra übernimmt
in den geprüften MBOX-/ENEX-Fällen deshalb den vollständigen Baum, meldet danach
aber `<quellname>/<quellname>.md` statt des tatsächlich erzeugten `index.md`.
Das muss vor der Integrationsabnahme im Fastra-Consumer korrigiert werden.
Unbekannte Fortschrittseinheiten werden ignoriert; LF-Dateinamen bleiben eine
Grenze des Textfortschritts. Ungültige UTF-8-Pfade sollen vor der künftigen
Linux-Konvertierung kontrolliert abgewiesen werden. Diese Validierung ist noch
nicht produktiv implementiert.

Empfohlene nächste Entscheidung: Swift als Kern beibehalten und den beschriebenen
Restaufwand für P03 sowie die begrenzten Backendfähigkeiten gezielt freigeben.
Für den späteren Umfang gibt es zwei belegte Alternativen: auf vollständiger
strukturierter OCR bestehen und P11 weiter offen halten, oder eine ausdrücklich
begrenzte Linux-Teilversion planen. Eine Teilversion darf strukturierte Erkennung,
RTFD und HEIC erst nach eigenen bestandenen Nachweisen anbieten. Die jetzigen
Befunde geben P05 weder automatisch frei noch ändern sie die bestehende Roadmap.

Die [Reproduktionsübersicht](../scripts/linux-probes/README.md) nennt Proben,
Abhängigkeiten und Grenzen. Dauerhaft bleiben nur Generatoren, kleine
normalisierte Antworten und Ergebnisbelege. Kopierte Programme und
Laufzeitbibliotheken gehören nicht ins Repository; entbehrliche Arbeitskopien
werden entfernt, spätestens 30 Tage nach Abnahme zur Entfernung vorgesehen.
