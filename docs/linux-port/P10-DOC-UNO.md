# P10: Linux-DOC mit explizitem UNO-Ladevertrag

Stand: 2026-11-05. Der Kandidat besitzt jetzt eine funktionierende echte DOC-Makro-Positivkontrolle. Derselbe OLE/DOC-Quellträger führt AutoOpen unter ausdrücklich erlaubender UNO-Einstellung aus und unter `NEVER_EXECUTE` nicht. Der Produkthelper enthält ausschließlich sichere Ladeparameter; der Pfad ist nach Integrationsreview in die Linux-CLI übernommen. Die neu gebaute gemeinsame Produktlaufzeit 0.41.10 wurde anschließend separat geprüft; die früheren Kandidatenergebnisse bleiben getrennt.

## Produktdateien und Integration

Der Linuxadapter liegt in `Sources/PoorMansTextCore/LinuxLegacyWordAdapter.swift`, der lokale Helfer in `Sources/PoorMansTextCore/LinuxBackends/legacy_doc.py`. Der Linux-DOC-Deskriptor und die Werkzeugauflösung registrieren diesen Pfad; macOS verwendet weiter seinen eigenen Adapter. Gezielte Regressionen stehen in `Tests/PoorMansTextLinuxTests/LinuxLegacyWordAdapterTests.swift`.

Erforderliche optionale Werkzeuge sind LibreOffice, zum System-Python passende UNO-Bindings (`python3-uno` als Capabilitykennung), Pandoc, bwrap und der lokale PMT-ProcessGuard. Der Modulcheck importiert UNO und seine verwendeten Schnittstellen, startet kein Office und erstellt kein Benutzerprofil. LibreOffice-Binary und UNO-Modul werden getrennt aufgelöst. Es gibt keine automatische Installation und keine eingebettete Office-Runtime.

Der Swift-Adapter prüft OLE/WordDocument, erzeugt einen verifizierten Snapshot und bindet ihn read-only. Der Helper wird durch den vorhandenen echten ProcessRunner mit privatem PID-/Netznamespace und begrenzter Laufzeit ausgeführt. Schreibbar bleiben nur privates Profil und Backendoutput. Der Officeprozess erhält kein DISPLAY, DBus-Userziel oder fremdes Profil; `SAL_USE_VCLPLUGIN=svp`, `--headless` und eine private UNO-Pipe werden ausdrücklich gesetzt.

Der Produktladeaufruf setzt immer `MacroExecutionMode=NEVER_EXECUTE`, `UpdateDocMode=NO_UPDATE`, ReadOnly, Hidden, Silent und OpenNewView. Ein InteractionHandler akzeptiert ausschließlich Abbruchfortsetzungen. Zusätzlich setzt das private Profil hohe Makrosicherheit und `DisableMacrosExecution=true`. Kein Argument oder Umgebungszweig schaltet den Produkthelper auf einen unsicheren Modus. [UNO MediaDescriptor](https://raw.githubusercontent.com/LibreOffice/core/libreoffice-26-8/offapi/com/sun/star/document/MediaDescriptor.idl), [MacroExecMode](https://raw.githubusercontent.com/LibreOffice/core/libreoffice-26-8/offapi/com/sun/star/document/MacroExecMode.idl), [UpdateDocMode](https://raw.githubusercontent.com/LibreOffice/core/libreoffice-26-8/offapi/com/sun/star/document/UpdateDocMode.idl).

HTML und unabhängiger TXT-Export stammen aus derselben geladenen Snapshotinstanz. Der bestehende HTML-Konverter übernimmt lokale Assets; eine Wortmultimenge aus TXT meldet kleinere Verluste und lehnt erheblichen Textverlust ab. Die vorhandene Legacy-DOC-Verlustdiagnose bleibt erhalten. Das behauptet keine vollständige Word-/Layout-/OLE-Objektparität. ReadOnly ist laut UNO eine logische UI-Einstellung; der schreibgeschützte Snapshot und die Prozessmounts sichern zusätzlich den tatsächlichen Dateizugriff.

## Verbindliche Ressourcenlimits

Der Pythonhelper setzt vor UNO-Import RLIMIT_AS soft/hard auf jeweils 3 GiB; der gestartete Officeprozess erbt diese Grenze. Für aktive soffice.bin-Prozesse wurde der tatsächliche Wert 3221225472 Byte in /proc/PID/limits gemessen. RLIMIT_CORE=0, RLIMIT_FSIZE=256 MiB je Datei und RLIMIT_NOFILE=512 bleiben gesetzt; RLIMIT_NPROC wird nicht verändert.

HTML wird vor Lesen und Decodieren auf 128 MiB und die unabhängige TXT-Referenz auf 64 MiB begrenzt. FD-gebundenes, blockweises Lesen hält das Limit auch bei Wachstum ein; UTF8-normalisiertes HTML wird vor dem Schreiben nochmals auf 128 MiB geprüft. Sparse Exportdateien von jeweils Limit+1 Byte wurden tatsächlich vor Decodierung abgewiesen. Swift prüft dieselben Exportbudgets beim FD-gebundenen Lesen und begrenzt auch Markdown auf 128 MiB. Der Wortvergleich zählt streamend, bevor Wörterbuchschlüssel aufgebaut werden: maximal 500000 Tokens je Text und 4096 UTF8-Bytes je Token; keine unbeschränkten split/map-Arrays. Die Eingabegrenze von 1 GiB bleibt ein separates Encoded-Source-Limit. Ressourcen werden nach Export zusätzlich auf insgesamt 512 MiB und 4096 Dateien geprüft.

Nach diesen Limits wurden die vier Swift-Tests, alle sechs CLI-Fälle/63 Checks, das Rich-DOC, die aktiven Office-Timeout-/Cancel-Fälle und der tatsächliche UNO-Exportfehler erneut erfolgreich geprüft.

## Echte Makro-Positivkontrolle

Aus dem benignen öffentlichen Apache-POI-`SimpleMacro.doc`, Commit `e3ad497b79b0135659c6b6d1c011e3fbabb91a14`, wurde ausschließlich der komprimierte VBA-Quellabschnitt des Moduls Module1 geändert: MODULEOFFSET 1587, unveränderte Streamlänge 179 Byte. Die neue öffentliche AutoOpen-Routine schreibt nur `m.sentinel` im eigenen Sandboxoutput. Anschließend wurde das echte DOC unter NEVER_EXECUTE um Unicode-Text, zwei echte Listenabsätze und ein eingebettetes vorhandenes PNG-Fixture ergänzt und als MS Word 97 gespeichert. Die ursprüngliche VBA-Storage bleibt erhalten. Originalfixture und Ableitung liegen mit Herkunft und originaler POI-Lizenz/NOTICE unter `scripts/linux-probes/p10-uno/input` beziehungsweise dessen Elternverzeichnis.

Der ursprüngliche kompilierte P-Code enthält weiterhin TestMacro. LibreOffice importiert und führt nachweislich den neu geschriebenen Quelltext aus. Diese Kontrolle qualifiziert den getesteten LibreOffice-Ladepfad; sie behauptet keine gleichartige Ausführung des unveränderten P-Codes durch Microsoft Word.

Bei Hiddenload unterdrückt LibreOffice den OpenDoc-Aktivierungspfad. Ein fehlender Sentinel nur bei Hidden=True wäre deshalb weiterhin kein positiver Sicherheitsnachweis. Der [LO-26.8-Aktivierungspfad](https://github.com/LibreOffice/core/blob/libreoffice-26-8/sfx2/source/doc/objmisc.cxx) prüft SID_HIDDEN, und [Writer koppelt OpenDoc an AutoOpen/Document_Open](https://github.com/LibreOffice/core/blob/libreoffice-26-8/sw/source/uibase/app/docsh2.cxx).

Die entscheidenden Paare laden deshalb beide mit Hidden=False innerhalb des ausschließlich kopflosen svp-Namespace ohne Display/DBus. Nur MacroExecutionMode unterscheidet sie: ALWAYS_EXECUTE_NO_WARN schreibt den Sentinel, NEVER_EXECUTE schreibt ihn nicht. Diese Paare wurden mehrfach mit frischen Profilen wiederholt und aus der tatsächlich ausgelieferten portablen Probe erneut abgespielt. Ein zusätzlicher NEVER_EXECUTE/Hidden=True-Lauf und der unveränderlich sichere Produkthelper bleiben ebenfalls ohne Sentinel. Das finale Kontrollfixture schreibt `/pmt/work-scope/m.sentinel`; der Harness bindet seinen privaten Output ausdrücklich auch an diesen Pfad. Beide Seiten jedes Kontrollpaares haben damit denselben beschreibbaren Sentinelpfad. Der echte CLI-Beleg qualifiziert separat Export, Hashes und Cleanup; ein ausbleibender oder nach Cleanup nicht mehr sichtbarer CLI-Sentinel wird nicht als eigener Sicherheitsnachweis benutzt. Der Kontrollharness verweigert den Start außerhalb des privaten PMT-Guard-PID1.

Finales Rich-DOC: 26112 Byte, SHA256 `490f2e2f0001bd676b27af70cd604d7bc1dc16c8afc6a3cead6859f7db3cc6c9`. Alle Kontrollen verwenden diese identischen Bytes. Vier unabhängige Textmarker bleiben jeweils einmal vorhanden, HTML enthält zwei Listenitems, und das eine exportierte PNG stimmt bytegenau mit dem Original überein: SHA256 `161e77431664be88483d7fef7bdd0123c9ed53318cfc9d1c4fa84af80ea2ab28`. HTML und TXT des entscheidenden positiven/negativen Paares sind identisch.

## Ausgeführte Prüfungen und I/O-Korrektur

Getestet: LibreOffice 26.8.1.1 (`bf8adb135da2784a1be3ca33001278b7a20af5c1` laut Binary), Python 3.14.9, Pandoc 3.1.3; Swift 6.2.1 im vorhandenen lokalen Ubuntu-Builder ohne Netzwerk. Passive Fixtureanalyse: olefile 0.47 und oletools 0.60.2 im separaten Probe-Venv.

- Vier gezielte Swift-Tests bestanden: WordDocument-Erkennung gegenüber XLS, nach Inspektion ausgetauschte Quelle, unabhängiger Textverlustvergleich sowie Tokenflut/überlange ASCII- und Mehrbyte-Tokens einschließlich erlaubter UTF8-Grenze.
- Die bestehende echte Sechs-CLI-Fälle-/63-Prüfungen-Matrix besteht: LibreOffice-DOC, textutil-DOC, Textbundle, Timeout, SIGTERM und ungültige Quelle; Inhalt, Listen, PNG, Quell-/Ausgabehashes und Cleanup bleiben geprüft.
- Die echte Swift-CLI konvertiert das finale Rich-AutoOpen-DOC mit beiden Listenitems und unveränderten PNG-Bytes; zwölf unabhängige Inhalts-/Manifestprüfungen bestanden.
- Zusätzliche aktive-Office-Prüfungen beobachten soffice.bin vor Abbruch beziehungsweise Timeout und halten dessen pidfd. CLI endet mit 130 beziehungsweise 124, der pidfd bestätigt Office-Ende, Ausgabe/Staging fehlen und die Quelle ist unverändert. Ein schreibgeschützter eigener Ziel-Elternordner liefert 74 ohne Publikation. Die portablen Übergabeskripte wurden aus neuen Arbeitsroots wiederholt.
- Der Reviewbefund zu UNO-I/O ist behoben: IOException ist keine Python-OSError; ErrorCodeIOException erbt von UNO-IOException. Ausschließlich storeToURL fängt diese Klassen strukturiert und erzeugt einen ExportOutputError; ein vorhandenes numerisches ErrCode wird übernommen. Kein Fehlertext wird zur Klassifizierung ausgewertet. Der Fehler liefert Helper- und CLI-Exit74.
- Der echte UNO-Schreibfehler wurde direkt und durch die vollständige Swift-CLI provoziert: inotify sperrt den eigenen privaten HTML-Ordner erst nach dessen erfolgreichem mkdir. LibreOffice ist bereits geladen; storeToURL wirft tatsächlich com.sun.star.io.IOException. CLI-Exit74, kein Ausgabeziel und kein Staging sind belegt. Dies war ein Berechtigungsfehler; ein tatsächlich volles ENOSPC-/Quota-Dateisystem wurde nicht erzeugt. Diese I/O-Ausnahmen laufen durch denselben strukturierten UNO-Basisklassenhandler.

Kompakte Kandidatenergebnisse stehen in [uno.json](P10-DOC-EVIDENCE/uno.json). Das ist eine Qualifikation dieser Linux-Werkzeugkombination, keine Zusage für alle künftigen LibreOffice-Versionen. Makro-Kontrollläufe sollten bei einem Backendwechsel oder relevanten LibreOffice-Update wiederholt werden. Eine zusätzliche aktive DDE-/Remote-Link-Positivkontrolle wurde nicht behauptet; NO_UPDATE, fehlendes Netzwerk und die read-only Eingabegrenze werden nicht gelockert. Ein nativer macOS- oder Mint-Lauf ist nicht Bestandteil dieses UNO-Belegs.

## Reproduktion

Die ausschließlich für isolierte Prüfungen vorgesehenen Kontrollwerkzeuge und benignen DOC-Fixtures liegen unter `scripts/linux-probes/p10-uno/`. `NOTICE.md` dokumentiert Herkunft und Hashes. Die dortige erlaubende Makrovariante ist kein Produktbackend und wird nicht paketiert. `cli_lifecycle.py` und `cli_export_error.py` prüfen aktive Officeprozesse und echte UNO-Ausgabefehler gegen eine ausdrücklich gewählte CLI. Alle Arbeitsverzeichnisse müssen eigene temporäre Testverzeichnisse sein.

## Gemeinsame Produktlaufzeit 0.41.10

Der integrierte Release-Build besteht dieselben sechs DOC-Fälle mit 63 Prüfungen.
Aktive-Office-Abbruch/Timeout bestätigen Exit 130/124, das geerbte 3-GiB-Limit und
Office-Ende über gehaltenen pidfd vor Cleanup. Ziel-Berechtigungsfehler und der
gezielt nach Office-Start herbeigeführte UNO-Exportfehler liefern 74 ohne Ausgabe
oder Staging. Der gesamte Swift-Regressionslauf besteht mit 338 Tests, davon acht
übersprungen, ohne Fehler. [Kleine Produktbelege](P10-DOC-EVIDENCE/product-04110.json)
enthalten den CLI-Hash; dies ist weiterhin keine Mint- oder Mac-Abnahme.

## Ubuntu-24.04-Zielbasis

Auch LibreOffice 24.2.7.2/Python 3.12.3 wurde im SDK-freien Ubuntucontainer geprüft.
Die erste Probe fand eine echte Laufzeitlücke: Ubuntu legt notwendige
Office-Registrierung unter `/etc/libreoffice` ab. Dieses eine Systemverzeichnis
wird jetzt zusätzlich read-only gebunden; der gesamte `/etc`-Baum bleibt außen.
Danach bestehen dieselben erlaubenden/gesperrten AutoOpen-Kontrollen mit
identischen DOC-Bytes, die sechs echten CLI-Fälle/63 Prüfungen sowie aktive
Office-Abbruch/Timeout und UNO-Schreibfehler74. [Zielbasisbeleg](P10-DOC-EVIDENCE/ubuntu-24.json).
