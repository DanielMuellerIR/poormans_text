# P13: Consumer-Replays und echter PMT-/Fastra-Öffnungslauf

Stand: 2026-11-05. Der Replay änderte kein Fastra-Repository. Vorhandene echte Consumer-/GTK-Binärdateien wurden unverändert in einen eigenen temporären Bereich kopiert; kein Consumer wurde neu gebaut. Sämtliche Fixtures, HOME-/XDG-Verzeichnisse und der GUI-DBus/Xvfb waren privat. Kein Produktdesktop wurde benutzt.

## Historische Consumer-Replays gegen0.41.10

[replay.json](P13-EVIDENCE/replay.json): Der vorhandene `fastra-import`-Treiber `examples/check_cli` läuft erfolgreich gegen PMT 0.41.10. Katalog: 29 Formate. CSV: eine Datei/ein Dokument, Einstieg `table.md`. MBOX: drei Dateien/zwei Dokumente, Einstieg `index.md`. Der originale Treiber prüft Adoption und unveränderte Quelldaten; seine temporären Verzeichnisse waren anschließend leer. Das ist ein echter Consumer-/Producer-Lauf, keine GUI-Abnahme.

[gtk.json](P13-EVIDENCE/gtk.json) und [gtk.log](P13-EVIDENCE/gtk.log): Der vorhandene echte Fastra-GTK-Importselbsttest bestand im vorhandenen lokalen WebKit-Builder unter privatem Xvfb/DBus ohne Netzwerk: Katalog, vollständige Vorschau ohne Veröffentlichung, abgewiesene Adoption nach tatsächlicher Revisionserhöhung, erneute Vorbereitung, bewusste Gesamtübernahme und Öffnen des richtigen `index.md` im Editor. Beide Unterdokumente und der Index bleiben vorhanden; der Quellhash bleibt gleich. Der erste Versuch endete vor der Importprüfung an einem fehlenden Harness-Marker für das tatsächlich private Display; der korrigierte Lauf bestand mit Exit 0 und `FASTRA_TOOL_SELFTEST_OK import`. EGL-/Fokuswarnungen der privaten Xvfb-Umgebung stehen im Log. Eine visuelle Desktopabnahme oder ein frischer GUI-Reopen nach Ende beider Apps wird daraus nicht behauptet.

Artefakt-SHA256:

- PMT-CLI 0.41.10: `c70a369fc76d0a5988931f5e32e4b16b57cc372bf3299e43b203c86b8c0ec157`
- PMT-Guard: `cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520`
- vorhandener Rust-Consumer `check_cli`: `ebb3feacdbab5b4ddf221b54b092697eb142d68f18cc6e84d03be29a5df2f061`
- vorhandene GTK-Anwendung: `9ee04a724e47d724d8adebdf2192a2df76b8a09f08fde220b928a2ce1cf6b4d4`
- Pandoc 3.1.3: `5a953bcbcdc7c36fcb0c263fbb09db8c7b84cfa9ca58e48e321d7edf857a7ee7`

Beobachtete Repository-Referenzen waren PMT `8ac57707c71747f6390b45180f874a02580bc636` mit laufenden 0.41.10-Änderungen und Fastra `f5fdc6268a5b07137fb35d522982d69068b5917c` mit umfangreicher aktiver Weiterentwicklung. Diese HEADs werden ausdrücklich nicht als unabhängig bewiesene Quellzuordnung der benutzten Binärdateien ausgegeben. Der Replay identifiziert die tatsächlichen Artefakte per Hash. Für die vollständige P13-Abnahme fehlen passende aktuelle Build-/Commitmanifeste beider Apps.

## Bereits vorhandene reale App-zu-App-Belege

Fastra `docs/LINUX-DECISION.md:58–89`, `docs/linux-port/BUILD-IDENTITIES.json` und `docs/linux-port/EVIDENCE.json` belegen native Mac-Sammlungen mit vollständigen Bäumen, PNG-Bytes, Kollisionserhalt und neuem Fastra-Prozess. Zugeordnet sind Fastra 1.157.2/365, Commit `4999717c12556c80ae69f2dd3aaf75ba6a94f108`, und PMT 0.41.7/92, Commit `5293eb6ce013512e791d9b7c7a5b89dd438c92ac`. Fastra-Executable-SHA ist `7ce0c836d453a2bb8c242d63d3d5b09dbae042afff5c5acf4796e3db6d753b16`; PMT-GUI-SHA `905ed9958aa421404259c0377417adf9470ba3241ce3e3c55cfa218a67a6a764`, eingebettete CLI `a0bd72a510a38b02b6305c04d5dc6fdc4cd09492f1b3b40ae5892234abc23ab3`. Diese vorhandenen Belege wurden hier gelesen, nicht auf dem Mac wiederholt. Der historische falsche Sammlungs-Öffnungspfad aus P01 ist damit in Fastra korrigiert.

Fastra `docs/linux-port/F13-IMPORT.md:127–183` dokumentiert außerdem reale Linux-CSV-/MBOX-Übernahmen und einen GTK-MBOX-Lauf gegen PMT 0.41.8. Die oben aufgeführten neuen Replays ergänzen diese um den tatsächlichen 0.41.10-Produzenten.

## Zuständigkeiten und nächste Schritte

Der aktuelle Status ist im [CLI-Vertrag](../FASTRA-CONTRACT.md) berichtigt: historische P01-Befunde bleiben als Historie erhalten, der dort noch offen beschriebene Sammlungsfix und die angeblich nicht implementierte Nicht-UTF8-Abweisung sind jedoch überholt. Letztere ist im aktuellen CLI-Vorabscan und in der P06-Abnahme implementiert. Der Linux-Rust-Consumer bewahrt Diagnosen, Dokumente, Berichte und Zusatzfelder bereits; die alte Aussage über hauptsächlich markdownFile/assets/warnings muss nach Mac- und Linux-Consumer getrennt werden. Ein neues Protokoll ist dafür nicht nötig.

Fastra besitzt die noch offene formatunabhängige Öffnungsintegration, den Katalogcache, Live-Fortschritt, Zieltab-/Projektbesitz und die Prozessaufsicht seines Imports. Der beim historischen .10-Replay gelesene gemeinsame Runner benutzte Prozessgruppen (`fastra-process/src/lib.rs:203–233,295–341`), keinen äußeren Namespace-/pidfd-Lifetimekanal. Daher ist eine neue gemeinsame Abnahme für harten GUI-Verlust und Namespace-Ende erforderlich; der hier erfolgreiche normale Import beweist diese Grenze nicht. PMT muss seine eigenen Schutzgrenzen dafür nicht abschwächen.

P13 bleibt insgesamt teilweise offen: vollständige Tabellen-/RTF-Encoding-/ENEX-/Verlust-/Missingtool-Matrix und Abbruch mit tatsächlichen Kindern gegen benannte aktuelle Consumerartefakte. DOCX mit PNG, gezieltes Öffnen aus PMT und frisches Öffnen nach Ende beider Apps sind inzwischen am .12-Artefakt belegt (unten). PMTs GTK-Öffnen startet gegenwärtig die Standard-App, nicht zwingend Fastra (`linux/app/src/main.rs:794–805`). Eine gemeinsame Abnahme kann eine explizite private Testzuordnung verwenden; daraus folgt kein automatischer Auftrag für eine neue PMT-Schnittstelle.

Der vorhandene `check_cli` nimmt nur den CLI-Pfad entgegen und erzeugt fest CSV sowie Plaintext-MBOX (`fastra-import/examples/check_cli.rs`). DOCX-/ENEX-/Fehlerfixtures können ihm nicht legitim als zusätzliche Argumente übergeben werden. Ein Wrapper, der Quelle/JSON umschreibt, wäre kein gleichwertiger echter Producer-/Consumerbeleg. Weitere Consumerfälle benötigen einen vorhandenen passenden GUI-Bedienweg oder eine gesondert beauftragte Erweiterung des Testtreibers durch dessen Eigentümer; ein neuer Ersatzconsumer wurde hier nicht gebaut.

P16 benötigt weiterhin die vereinbarte aktuelle Format-/Funktionsmatrix auf beiden Linux-Zielen, echte Desktop-/Paketabnahme, längere Serien und den nativen Mac-Regressionsschutz der gemeinsamen Änderungen. Die alten Mac- und neuen begrenzten Linux-Belege dürfen diese Gesamtfreigabe nicht ersetzen.

## Portabler Wiederholungsweg

Der Originaltreiber wird mit genau einem Argument gestartet: `check_cli /absoluter/pfad/zur/poormans-text`. HOME, TMPDIR und XDG-Verzeichnisse vorher auf einen eigenen temporären Bereich setzen; die PMT-CLI braucht ihren zugehörigen Guard und Runtime. `check_cli` erzeugt seine CSV-/MBOX-Fixtures selbst.

Die Dateien unter `scripts/linux-probes/p13/` (`gui-run.sh`, `test-dbus.conf` und `source.mbox`) sind die tatsächlich verwendeten kleinen GTK-Harnessdaten. Der Runner erwartet im privaten Container den eigenen Arbeitsbereich `/work`, das vorhandene GUI-Artefakt `/app/fastra-linux` samt benötigter privater ICU unter `/app/lib`, den passenden PMT-Launcher `/work/poormans-text`, dessen Runtime und das explizit gewählte Pandoc in `/work/bin`. Unter `/work/gui-fixture` liegen Quelle, neuer Zielordner und ein CLI-Launcher namens `poormans-text`. Der äußere Lauf verwendet ein bereits vorhandenes passendes GUI-Builderimage, `--network none`, einen eigenen Benutzer, `--ulimit core=0` und nur diese privaten Mounts. Die im verwendeten Image nötigen Docker-Ausnahmen `seccomp=unconfined` und `systempaths=unconfined` erlauben die inneren bwrap-Namespaces; WebKits eigene Sandbox wird nicht deaktiviert. Der Runner benutzt eigenständiges Xvfb und DBus und setzt den geforderten `FASTRA_ISOLATED_DISPLAY=1`-Marker nur in dieser tatsächlich privaten Umgebung. `published/` bewahrt die drei kleinen realen Ergebnisdateien nach Prozessende, keine Binärdateien oder Entwicklungsruntime.

## Finaler Produktionslauf0.41.12 → Fastra1.158.0

[Bericht samt Nachweisen](P16-04112/arch-fastra/REPORT.md): Produktions-PMT
konvertiert ein echtes DOCX mit PNG, Tabelle und Unicode. Der tatsächliche
GIO-Button öffnet die Markdown-Datei über eine ausschließlich private
Standard-App-Zuordnung im neuen echten Fastra-PID. Der vollständig gelesene
Editorpuffer entspricht bytegenau dem Markdown; Bildlink und Original-PNGhash
sind geprüft. Nach Ende beider Apps ergibt ein normaler argv-Neustart und
zusätzlich ein neuer Home-/Displaylauf mit vorher leerer Clipboard denselben
Puffer. `first.png` nach Copy (selektierter Editor) und `fresh-before-copy.png` vor
Copy wurden visuell geprüft; die spätere schwarze Aufnahme ist kein Bildbeleg. Bildrenderung und
semantische Formatparität werden daraus nicht abgeleitet.

PMT-CLI2f49d54e… und GTK918a8d2b… stehen im Bericht vollständig; Fastra-ELF
`e83f7e59677a39db95f60a5b9501746a3a8df492b0fcd086f7fa356480e03582`
(1.158.0/366) wurde nicht neu gebaut. Alle45 PMT- und370 Fastraeinträge bleiben
hashgleich, alle eigenen Container und großen Kopien sind entfernt. Das
Fastra-source_sha256-Feld ersetzt keine unabhängig bewiesene Gitcommitbindung.
Fastraquellen wurden nicht geändert; Consumerarbeit bleibt beim Fastra-Chat.
