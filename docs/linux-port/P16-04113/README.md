# Produktnachweise 0.41.13

Stand: 2026-11-05. Der gemeinsam verwendete Swift-Kern erhält zwei abgegrenzte
Linux-Änderungen: weitere statische RTFD-Bildanhänge und korrekte Besitzprüfung,
wenn die CLI selbst Namespace-PID 1 ist. GTK-Code und Mac-Konverterlogik sind
gegenüber 0.41.12 unverändert; die Versionsangaben sind 0.41.13/build 98.
Dies ist eine geprüfte Entwicklungsvorschau, keine vollständige Linux-/Desktop-
oder Distributionsfreigabe. Die [0.41.12-Nachweise](../P16-04112/README.md)
bleiben ihrem eigenen Artefaktstand zugeordnet.

## Finale Artefakte

- CLI SHA256 `26470eaf5d0b474e7f164882683b339ffc63b75d20a3ecdd6856729883f8f460`.
- GTK SHA256 `851d0a76e4214bbd5f599c995a1b78ff40792524a7b1383e6afbda165c43cfa6`.
- Guard unverändert `cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520`.
- Geprüfte C-Quelle `56066ab58b87fe3f614ccac00a20caa0005872081f29204a385ef57990dddc9d`.

## Tatsächlich ausgeführte Prüfungen

| Nachweis | Ergebnis und Grenze |
| --- | --- |
| [Swift-Tests](swift-tests.log.gz) | 350 Testfälle, 0 Fehler, 11 bedingte Skips, 37,079 s. Die zwei nicht ausgewählten OCR-/PDF-Fixturetests separat [mit echten Fixtures bestanden](selected-fixtures.log.gz),2 Tests/0 Fehler/0 Skips. Neun übrige Corpus-/Fähigkeitsskips bleiben benannt; keine Behauptung einer übersprungenen Prüfung. |
| [RTFD im SDK-freien Noble](rtfd/README.md) | 25/25 echte CLI-Fälle, 12 positive und 13 erwartete negative; BMP und HEIC erhalten Originalbytes/Positionen, Mehrframes und unsichere Pakete veröffentlichen nichts. Alle 33 überwachten Quellen-/Artefakthashes gleich. |
| [C-Besitzprüfung als echte PID 1](pid1-ownership/README.md) | Eigene direkte/tiefere Nachkommen sowie PID 1 selbst akzeptiert; 100 Geschwisterprüfungen mit ESRCH abgewiesen, Ziele bleiben lebendig, FD-Zahl4→4, alle eigenen Kinder eingesammelt. Kein Ersatz für den Produktlauf. |
| [Echte Swift-CLI als PID 1](pid1-product/README.md) | SDK-frei, beobachtete PID 1/PPID 0/UID 1000; echtes RTF → Pandoc, Exit 0. Alle 12000 Unicode-Absätze in Reihenfolge, SourceIdentity, Quellbytes und sämtliche Ausgabemanifeste unabhängig geprüft. |
| [17 Runnerverlustfälle](runner-loss.json) | Timeout 124, Cancel 130, Runner-/Wrapper-/Guardverlust plus 12 Startupverluste bestanden. Namespaceende vor Cleanup, Heartbeat beendet, Lease-Reopen verweigert, Quellen unverändert, keine Veröffentlichung. |
| [48 Neustarts](series.json) | 374/374 Fallprüfungen, 26,423 s; 40 positive Jobs und 8 erwartete Fehler. Einheitlicher beobachteter ELF, Manifest-/UTF8-Grenzen und Quellen stabil, keine Restnachkommen. |
| [Drei Pakete](packages.json) | Debian/Arch/Tar unter umask 077, relocierte Unicode-CSV, öffentliche Dateimodi und Hashes korrekt; Kollision 73 verändert nichts, Symlinkeltern bleiben ohne Ausgabe. |
| [Native Mint](mint/README.md) | 25/25 RTFD-Fälle einschließlich HEIC/BMP plus echtes DOCX mit unverändertem PNG; Produktions-GTK-CSV im privaten Xvfb/DBus bis Completed/Unicode. Paket nur unter /tmp extrahiert, keine Installation. Alle Runtime-/Quellhashes gleich; Remote-Dateien und Prozesse entfernt. |
| [Arch/Wayland](arch-wayland/README.md) | Regulär .12 installieren → .13 upgraden → entfernen, unveränderte Paketpolicy, SDK-freie UID 1000. 25 RTFD-Fälle bestanden; Produktions-GTK unter privatem Weston/Wayland per AT-SPI bis Completed/Unicode, native Aufnahme visuell geprüft. |

Die echte volle ext4-, gebundene Nichtüberschreib-/Zieltausch- und harte
Prozessverlustprüfung aus P03/P06 bleibt erhalten; diese Dateipublikation wurde
hier nicht geändert. Rust-Unit-/Clippy-Belege 0.41.12 betreffen unveränderten
Rustcode; der .13-Releasebau wurde neu ausgeführt. Keine künstlich erhöhte neue
Rust-Testzahl oder zusätzliche Mac-Suitebehauptung.

Ein erster Testbuild scheiterte vor Testausführung an einem eigenen, von
früheren UID-65534-Läufen anders besessenen Cache. Nach gezielter Besitzkorrektur
nur dieses generierten Caches gelang der Testbuild. Der bekannte unveränderte
Mac-OCRAsyncBridge-Stall bleibt außerhalb der grünen Mac-Restregression 0.41.12.

## Grenzen, Wiederholung und Cleanup

[RTFD-Verhalten und Kandidatenabgrenzung](../P10-RTFD-STATIC.md). Die neuen
Releasefälle ersetzen keine vollständige RTFD-/PDF-Layoutparität. Die fehlende
native Mint-Paketinstallation wurde [begrenzt untersucht](mint-package-capability/README.md):
Namespaces funktionieren, der Overlaymount scheitert. Keine Systemdateien,
Pakete oder Paketdatenbanken wurden geändert; alle eigenen Remote-Tempdaten
sind entfernt. Das ist kein Beweis einer generellen Kernel-Unmöglichkeit,
aber auch keine freigegebene Installationsumgebung.

P11 bleibt ohne sicheren Produktadapter/qualifizierten Korpus offen; siehe
[Docling-Entscheidung](../P11-DOCLING.md). Echte KDE-/Cinnamon-Systemintegration,
vollständige Consumer-/Formatmatrix und Distribution bleiben eigene Abnahmen.
Für aktuelle Fastra-Importtests fehlt ein fertig benanntes, vollständig an
Quellen gebundenes neueres Produktartefakt. Das alte 1.158-Editorartefakt trägt
keinen belegten Importdialog; sein bestandener .12-GIO-/Reopen-Lauf wird nicht
als neuer Importtest umgedeutet. Fastraquellen wurden hier nicht geändert.

Reproskripte und kleine Quellen/JSON-Belege liegen bei; immer vorhandene lokale
Images ausdrücklich wählen und automatisches Nachladen mit `--pull never`
ausschließen. Rohreproduktionspfade sind eigene private Testpfade. Beigefügte
SHA256SUMS bleiben die unveränderten ursprünglichen Liefermanifeste. Die
normalisierten komprimierten Testlogs ersetzen nur private Kompilierpfade
mit `$REPO`. Eigene Testcontainer/Quell-/Runtime-/Outputkopien der Unterproben
sind entfernt; entsprechende Cleanupbelege liegen bei. Kleine Belege bleiben
mit Prüfdatum erhalten.

Mint-Rohlogs liegen bytegetreu komprimiert als `.log.gz` bei; die Hashes des
ursprünglichen Liefermanifests beziehen sich auf den entpackten Inhalt.
