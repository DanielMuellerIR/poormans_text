# Native Mint 0.41.14: Legacy-DOC

**Zwei echte native DOC-Produktfälle bestanden** mit vorhandenem LibreOffice24.2.7.2 420(Build:2) und UNO. Normales libreoffice.doc sowie bekanntes synthetisches RichAutoOpen.doc werden erfolgreich konvertiert. Das endgültige Paket wurde ausschließlich privat mit dpkg-deb-x extrahiert; Pandoc3.1.3 unverändert nur nach/tmp übertragen und ausdrücklich per --pandoc übergeben. Keine Hostinstallation, Downloads, Overlay oder Host-GUI.

Identität: PaketSHA c93e87876b3882fe078f93cd27741937d4368c32bfe6cb3924fcb4e212e19cb0; CLI8abc9197eeced8df043d788e349acb553bd86dd81546a6fda1faf15a93bac0cb; GUI85e70bf0654f4b308a5db2d483eaf258dd376f83773703febe23fa91d05ddcf2; Guardcf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520; Pandoc5a953bcbcdc7c36fcb0c263fbb09db8c7b84cfa9ca58e48e321d7edf857a7ee7.

## Tatsächliche Prüfung

Vor dem Produktlauf meldet der Backendkatalog mit dem expliziten privaten Pandoc den DOC-Pfad verfügbar. Ein anfänglicher Probenaufruf ohne --pandoc meldete korrekt „missing required tool: pandoc“ und wurde vor DOC-Konvertierung abgebrochen; dieser reine Probenparameter wurde korrigiert, kein Produktfix.

Normales DOC: Heading/Unicode, beide Listenitems, Tabelle Äpfel/Birnen, Grüße aus Köln und Fußnote bleiben erhalten, jeder unabhängige Marker genau einmal. Rich-DOC: PMT UNO DOC ä Grüße, zwei kontrollierte Listenitems und IMAGE-FOLLOWS jeweils genau einmal. Beide Konvertierungen liefern genau zwei lesbare Listenitems, die bestehende Legacy-Verlustwarnung und genau ein PNG mit unveränderten Originalbytes SHA161e77431664be88483d7fef7bdd0123c9ed53318cfc9d1c4fa84af80ea2ab28. SourceIdentity und sämtliche Ergebnis-/Reportmanifestgrößen und -hashes stimmen; Quelldateien unverändert.

Der ausgelieferte sichere Helper wurde gehasht und verwendet ausschließlich NEVER_EXECUTE/NO_UPDATE; kein ALWAYS_EXECUTE-Zweig, keine unsichere Makrokontrollvariante übertragen oder ausgeführt. Das bekannte26112-Byte-Rich-DOC hat SHA490f2e2f0001bd676b27af70cd604d7bc1dc16c8afc6a3cead6859f7db3cc6c9. Keine Sentineldateien im eigenen Arbeitsbaum beobachtet. Dies allein ist ausdrücklich **keine neue unabhängige Makro-Positivkontrolle** für Mint: P10 dokumentiert den früheren Kontrollnachweis und die Grenzen eines bloßen fehlenden Sentinels nach privatem Jobcleanup. Auch keine neue DDE-/Remote-Link-Positivkontrolle behauptet.

Der komplette Produktlauf lief in User/PID/Net/Mount/IPC/UTS-Isolation mit Hostroot readonly, privatem Home/root/run/tmp/dev/proc und nur eigener/tmp-Wurzel schreibbar. Hostprofilpfade waren verborgen; LibreOffice bekam zusätzlich das vorhandene private Produktprofil. Netzwerk/Hostdesktop/Sessionbus waren nicht zugänglich. Host-LibreOfficeprofil wurde ausschließlich über gehashte Dateinamen/Metadaten vor/nach verglichen, keine Profilinhalte gelesen. Profilmetadaten, /usr/bin/true und Host-Paketdatenbank blieben gleich. Eigene Restprozesse0, gesamter Remote-Arbeitsbaum entfernt. Maximal362598950Bytes, unter400MiB; neue Netzdownloads0.

## Reproduktion und Grenze

Die vorhandenen P10-DOC-/UNO-Dokumentation und versionierten WordProcessing-/RichAutoOpen-Fixtures wurden wiederverwendet, kein neuer DOC-Generator. Die kleinen Laufquellen und JSONs liegen bei. run_remote.py erwartet eine eigene/tmp/pmt-mint-doc14.*-Wurzel mit dem unveränderten Paketbaum, Pandoc und denselben relativen Fixturepfaden. verify_inside.py ruft den realen ausgelieferten CLI-/Guard-/LibreOffice-/UNO-Pfad auf. Die historische Cleanupquelle bindet ihre Löschung an den eigenen Prüfscript-Hash. Pakete/Runtime/Pandoc sind nicht im Belegarchiv dupliziert.

Der optionale native Produktionszoomlauf wurde nicht gestartet: Es gab keinen fertigen passenden Produktions-AT-SPI-Zoomablauf; vorhandene Zoomscripts waren Selftest beziehungsweise manueller Start/Wait. Kein neues Testwerkzeug gebaut. Der `.14`-GUIhash ist als Paketinhaltsidentität geprüft, keine native `.14`-GUI-/Zoomfunktionsabnahme. Frühere native `.13`-CSV- und PDF-Belege bleiben getrennt.
