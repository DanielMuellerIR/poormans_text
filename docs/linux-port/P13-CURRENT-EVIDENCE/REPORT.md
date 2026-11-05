# PMT0.41.14 → Fastra1.164.0: echte Linux-Importabnahme

2026-11-05, abgeschlossen gegen den unveränderten Produzenten8abc9197… und den Release-Consumer810ed0a7…. Keine Repo-/Gitänderungen, kein Neubau und kein Ersatzconsumer. Alle Importaktionen liefen im echten Tools→Import document-Dialog mit echten Maus-/Tastaturereignissen. JSON, Quellargumente und Ergebnisse wurden nicht umgeschrieben.

## Identität und Umgebung

`identity.json` bindet die vollständigen Hashes. Fastra-Laufzeit: `$FASTRA_RUNTIME`; alle375 Manifestdateien wurden vor und nach dem Test unabhängig gehasht, keine Abweichung. Version1.164.0/372 und source_sha256 stimmen mit `fastra/docs/linux-port/F16-1.164.0-EVIDENCE.json` überein. Dessen Sourcearchiv-/Commitnachweis bindet f8e2bdc4933327ce2334ccb5450cb431273ef5bd; die273 Sourcevergleiche wurden hier gelesen, nicht wiederholt.

PMT kam read-only aus `.build/linux-runtime`, der unveränderte Rootlauncher lag in einer privaten Kopie mit `.build/linux-runtime → /pmt`. Die finale CLI blieb vor/nach gleich. Es wurde ausschließlich das vorhandene Image fastra-linux-git-check verwendet, UID1000, Netzwerk none, private HOME/XDG-Verzeichnisse, eigenes Xvfb/DBus, keine Hostanzeige und kein Hostinstallationspfad. Docker-Ausnahmen systempaths/seccomp/apparmor=unconfined entsprachen dem vorhandenen privaten GUI-Prüfweg; keine WebKit-Sandbox-Deaktivierung. Die äußere Dockerisolation ersetzt keine Desktopfreigabe.

Der aktuelle Debugpfad `/var/tmp/fastra-root-1164-final-debug/app/libexec/fastra-linux` hat zwar den dokumentierten Hash b4dbc89f…, sein mitgeliefertes Manifest nennt aber Build371 und einen anderen ELFhash. Er wurde deshalb nicht als gebundenes Testprodukt benutzt. Auch `target/debug/fastra-linux` ist ein anderes älteres Artefakt31a1abaa….

## Ergebnis

| Fall | Echter Dialog und unabhängige Outputprüfung |
|---|---|
| CSV | Vorschau mit Alpha17/Café23, Adopt nach absichtlich vorhandener Kollision csv. Tatsächlich csv-2/table.md; alter Marker bytegleich. |
| MBOX | Zwei echte Nachrichten, drei Markdowndateien, Sammlungseinstieg index.md; beide Betreffe und Bodymarker unabhängig gelesen. Neuer Editor-Tab zeigt beide relativen Dokumentlinks. |
| DOCX+PNG | Pandoc erzeugte ein echtes temporäres DOCX mit Unicode, PNG und Tabelle aus picture.md. Vorschau zwei Dateien, Adopt picture.md. Titel/Body/Tabelle/Bildlink geprüft; PNG bytegleich zum Originalhash161e7743…. |
| ENEX | Zwei Notizen mit eigenem Body, Metadaten und demselben PNG. Vorschau sieben Dateien und sichtbare html.structureSimplified-Warnungen/Diagnosen; Adopt index.md. Drei Markdown- und vier PNGdateien vollständig vorhanden; beide Bodies und alle PNGhashes unabhängig geprüft. Editor öffnet echten Sammlungseinstieg. |
| RTF-Encoding | Ein echtes RTF mischt1252 mit fcharset204. Vorschau und adoptierter UTF8-Text exakt „Grüße Привіт PMT17“. |
| Missingtool | Vor Bereitstellung von Pandoc zeigt derselbe DOCX-Dialog „Pandoc was not found. Install Pandoc or pass --pandoc PATH.“; Adopt bleibt aus, kein Ziel/Staging. |
| Cancel CLI | 300000 CSVzeilen; tatsächlicher PMT-PID786 vor Cancel belegt. Nach2s weg; „Cancelled. Nothing adopted.“, kein Ziel/Staging. |
| Cancel echte Kinder | Großes DOCX mit100000 Absätzen. Vor echtem Cancel liefen CLI980, bwrap1001, guard1002 und Pandoc1003. Nach2s alle weg; kein Ziel/Staging. Prozesslisten und Screenshot liegen bei. |
| Frisches Öffnen | Nach vollständigem Ende des Importcontainers neuer Container/neues HOME ohne PMTmount. Normaler argv-Start auf adoptiertes DOCX-Markdown; native Vorschau zeigt Titel, Unicode, tatsächliches PNG und Tabelle. |

Fünf Positivformate, eine Kollision, ein Missingtool, zwei echte Abbrüche und ein frischer Öffnungslauf bestanden. Die Vorschauen, Adoptionsmeldungen und ausgewählten Editoransichten wurden visuell angesehen. `verified.json` enthält unabhängige Inhalts-/Hashprüfungen und den vollständigen kleinen Ergebnisbaum. Die Hauptfixtures einschließlich cancel.csv stimmen mit ihren vor der Matrix erfassten Hashes überein. Der später erzeugte cancel-child.docx besitzt keinen unabhängigen Vorherhash; die Prozessorientierung und fehlende Veröffentlichung sind dagegen belegt.

Pandoc3.1.3 stammt unverändert aus dem vorhandenen pmt-linux-backend-test-Image. Nur im eigenen Container wurden /usr/local/bin/pandoc, zwei fehlende Bibliotheken und /usr/share/pandoc bereitgestellt. Ein erster Positivversuch ohne Daten meldete nachvollziehbar das fehlende abbreviations-File; nach gezielter Ergänzung bestanden die Positivfälle. Diese Hilfsruntime wurde am Ende entfernt.

## Grenzen

Dies ist eine begrenzte Ubuntu/X11-Abnahme, kein vollständiger F13/P16-Abschluss: keine Wayland-/Desktopintegration, Macabnahme, echte IME, Formatvollmatrix, Dateisystem-/Stromverlusttests oder absichtlich ausgebrochene Nachkommen. Kein Beweis vollständiger visueller Formatparität. Der Importdialog hat keinen Live-Producerfortschritt; die Tests nutzen seinen vorhandenen Prepare/Adopt/Cancel-Weg. Keine Aussage zu zukünftigem PMT0.41.15.

Alle eigenen Container wurden entfernt. Große Hilfskopien/Privatprofile sind entfernt; nur diese kleine Lieferung bleibt. Testreferenzen dienen einer Wiederholung/Übernahme durch den zuständigen Chat; nächste Prüfung2026-12-05, entbehrliche Kopien spätestens30Tage nach Abnahme entfernen. Screenshots nicht ungeprüft in öffentliche Repos übernehmen.

## Übergabe an Fastra

Das bisherige P13-Artefakttor ist für Release1.164.0/372 gelöst. Echter formatneutraler Import ist gegen PMT0.41.14 für CSV/MBOX/DOCX+PNG/ENEX+PNG/RTF-Encoding inklusive Kollision/Missingtool/Abbruch mit Pandocnachkommen belegt. F13 darf diese konkrete Matrix ergänzen; vollständige Produkt-/Macparität bleibt offen. Das Debugmanifest passt aktuell nicht zum ausgelieferten Debug-ELF, bitte bei einer späteren Debuglieferung neu binden. Keine Fastraänderung wurde hier vorgenommen.

Die synthetischen GUI-Screenshots liegen privat außerhalb des Repositories; ihre Dateihashes bleiben im ursprünglichen SHA256SUMS-Verzeichnis erhalten. Strukturierte Belege und kleine Dokumentfixtures sind hier versioniert.
