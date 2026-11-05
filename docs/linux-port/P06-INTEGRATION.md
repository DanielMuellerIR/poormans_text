# P06: Linux-CLI und produktive Sicherheitsabnahme

Stand: 2026-11-05, Produktstand 0.41.9. Der sichere Linux-Datei-/Prozesspfad ist
produktiv integriert; die unten genannten Läufe verwenden den vollständigen
Konverter. Die früheren P03-Entscheidungsproben werden getrennt geführt.
Eine vollständige GUI-/Fastra-/Mac-Abnahme folgt daraus nicht.

## CLI, Formate und Portabilität

39 echte CLI-Fälle mit 315 Einzelprüfungen bestehen im Releasebuild: Katalog,
Hilfe/JSON/Fortschritt, aktivierte Pandoc-Formate, DOCX-Änderungsmodi, EPUB-Auswahl,
Frontmatter, Textbundle, stdout-Grenzen, fehlende Werkzeuge, unsichere Dokumente
sowie paralleler Ordnerimport mit fortgesetzter Bearbeitung nach einem Einzelfehler.
Der lokale HTTP-Sentinel verzeichnet keinen entfernten Abruf. Quellbytes,
Markdown-/Assetbestand und Berichte werden unabhängig geprüft. Der kleine
[CLI-Beleg](P06-EVIDENCE/cli/matrix.json) hält die tatsächliche Binärdatei und
Werkzeugversion fest; Reproduktion: `scripts/linux-probes/p06/verify_cli.py`.

Die gemeinsame native Linux-Suite führt **334 Fälle** aus: **326 bestanden,
acht ausdrücklich übersprungen, null Fehler**. Sie verwendet Originaltests für
Formate, Profile und EPUB direkt, ergänzt portable XML-/Konverterprüfungen und
Linux-Sicherheits-/Backendregressionen. Die fehlenden externen Referenzen und der
fehlende unabhängige Pandoc-XLSX-Reader stehen im
[Testbeleg](P06-EVIDENCE/integrated-tests.json); Skips sind keine bestandene Abnahme.

Behobene tatsächliche Portierungsfehler sind FoundationXML-Abstürze beim DTD-
Zugriff und beim EPUB-Ancestorpfad, fehlende Attribute im Default-Namespace,
verlorene DocBook-Titel und unzuverlässige XML-Fehler-/Entitymeldungen.
[Format-/XML-Bericht](P07-P08-INTEGRATION.md) und
[Backendbericht](P09-P10-INTEGRATION.md) erklären Umfang und Grenzen.

## Linux-Dateinamen und Quellgrenzen

Ungültige UTF-8-Dateinamen werden beim Verzeichnislesen ausdrücklich abgewiesen;
Foundation darf sie nicht still auslassen oder über ersetzende Anzeigenamen
verwechseln. Aufgelöste Aliasziele und Ausgabeeltern werden ebenfalls geprüft.
Ein tatsächlich gültiges Ersatzzeichen U+FFFD bleibt zulässig.

Swift-Strings vergleichen Unicode-kanonisch, Linux-Dateinamen dagegen als Bytes.
Ein gemeinsamer Pfadhelper trennt daher NFC/NFD-Quellen, Plan-/Berichtsidentitäten,
Assetcaches und Sicherheitspräfixe. Die Stapelreservierung unterscheidet
auch tatsächlich verschiedene Groß-/Kleinschreibungen; fehlende Foundation-
Volumemetadaten erzeugen keine künstliche Ausgabekollision. Die Regressionen belegen zwei erhaltene
CSV-Quellen, getrennte lokale/Webarchiv-Bilder, beide RTFD-Attachmentprüfungen
sowie abgewiesene HTML-/ODM-Sibling-Escapes und fremde Prozessschreibbereiche.
Notebook-JSON mit kollidierenden Objektschlüsseln wird vor Foundation kontrolliert
abgewiesen, statt unbemerkt ein Bild zu verlieren. Einzelne NFC-/NFD-Namen bleiben
zulässig. Die gezielte Prüfung ersetzt keinen vollständigen Audit aller Pfade.

## Prozessverlust im vollständigen Produkt

Fünf tatsächliche CLI-Läufe bestehen Timeout, SIGTERM sowie harten Verlust von
Runner, Wrapper und Guard. Gehaltene pidfds belegen das Namespace-Ende vor dem
äußeren Cleanup; ein geöffneter Heartbeat-FD zeigt danach keine weiteren Writes.
Ein Kindprozess kann den Lebensdauerkanal nicht über `/proc/1/fd/0` wieder öffnen.
Zwölf weitere Runnerverluste zwischen sofortigem Start und 0,5 Sekunden bestehen
auch vor bzw. während des Namespace-Infoprotokolls. Der äußere Subreaper wartet
vor jeder Entfernung auf alle eigenen Nachkommen. Quelle bleibt unverändert;
kein Fall publiziert ein Ergebnis. [Belege](P06-EVIDENCE/runner-loss.json),
Reproduktion: `scripts/linux-probes/p06/verify_runner_loss.py`.

Nach hartem Runnerverlust bleibt die separate Endebarriere Aufgabe des äußeren
Besitzers; Runnerexit allein ist keine sichere Cleanupfreigabe. Eine getötete
Anwendung kann eigenes Staging nicht selbst entfernen. Der Prüfer räumt dessen
Dateien erst nach der bestätigten Endebarriere auf. Ununterbrechbare Kernel-/
Hardware-I/O bleibt außerhalb dieser Abnahme.

## Mint ohne Swift-SDK

Der identische Releasebuild läuft auf Mint ohne Swift-SDK. Bestanden sind CSV mit
Unicodepfad/Hashes, PNG ohne OCR, zwei byteverschiedene NFC-/NFD-Quellen im
parallelen Stapel und die ausdrückliche Abweisung ungültiger UTF-8-Namen.
Fehlendes Poppler/Pandoc ergibt jeweils 69 ohne Ausgabe; der Katalog meldet das
fehlende PDF-Backend korrekt. Die tatsächlich nicht installierten Werkzeuge
wurden nicht nachinstalliert. Damit ist kein erfolgreicher Mint-PDF-/OCR-Lauf
behauptet. [Kleiner Beleg](P06-EVIDENCE/mint-runtime.json).
Die eigene Laufzeitkopie samt synthetischen Fixtures wurde unter `/tmp` geprüft
und anschließend vollständig entfernt; die Entfernung wurde erneut kontrolliert.

## Voller Speicherplatz auf echtem ext4

Der vollständige Releasekonverter 0.41.9 wurde in einer isolierten Umgebung als
UID 65534 auf einem eigenen 64-MiB-ext4-Image ausgeführt. Bei freiem Platz erzeugt
CSV Markdown, Bericht und vier Quellzuordnungen. Quelle und vorhandenes Ziel
bleiben bytegleich. Danach wurde das Image mit echten Kernel-Schreibzugriffen
gefüllt. Ein fehlgeschlagener 1-MiB-Write genügte noch nicht: Eine kleine
CSV-Konvertierung konnte den Restplatz weiterhin nutzen. Erst ergänzende
synchrone 4-KiB-Schreibzugriffe erschöpften den verfügbaren Platz vollständig.

Bei **null verfügbaren Blöcken** scheitert die echte Konvertierung mit Exit 74
und ENOSPC. Sie veröffentlicht kein Ergebnis und hinterlässt kein Staging;
Quelle und bestehendes Ziel bleiben unverändert. Nach Entfernen der Fülldatei
gelingt dieselbe Konvertierung wieder vollständig. Das eigene Loopgerät wurde
ausgehängt und freigegeben, das Image entfernt. Die fehlgeschlagenen Vorversuche
haben ebenfalls keine Images oder Loopzuordnungen hinterlassen.

Reproduktion nach dem Linux-Build und mit vorhandenem lokalen
`pmt-p03-fs-probe`-Image:

```sh
bash scripts/linux-probes/p06/run_product_ext4.sh
```

Das Skript benötigt Docker mit Loop-/Mount-Rechten. Es erzeugt ausschließlich
ein eigenes Image unter einem neuen `/tmp`-Verzeichnis. Es bindet die fertige
CLI und ihre Laufzeit read-only ein; keine Ersatzimplementierung des Kerns.
Kleine Ergebnisse stehen unter [P06-EVIDENCE/product-ext4](P06-EVIDENCE/product-ext4/full.json).
Die temporären Ausgaben der ausgeführten Prüfung wurden nach Sicherung dieser
Belege entfernt.
