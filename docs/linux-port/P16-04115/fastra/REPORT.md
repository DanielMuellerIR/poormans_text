# Gezielter PMT0.41.15→Fastra1.164.0-Replay

2026-11-05. Der echte Release-Importdialog besteht erneut DOCX+PNG. Normale und verschlüsselte ENEX-PDF-Quellen werden mit sichtbarer MissingBackend-Diagnose und gesperrter Adoption abgewiesen. Die positive ENEX-PDF-GUI-Abnahme bleibt eine konkrete Umgebungslücke. Die bestehende0.41.14-Vollmatrix wurde nicht wiederholt.

ProducerCLI: d354636d818849f8acbea9ad59a41aa91caf5083a07eda4331897288bb6c85e6. Guard laut unverändertem Artefakt cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520. PMT war ein dirty0.41.15-Kandidat; es wird keine Bindung an einen bereits abgeschlossenen Commit behauptet. Der übergeordnete Produktbericht bindet den geprüften Build an den gesicherten Quellstand.

Consumer: kanonische vollständige Release-Laufzeit `$FASTRA_RUNTIME`,1.164.0/372, ELF810ed0a78a1b89042781d5dfc050bcc42ae9b0c42dcb40b3b6f068db858f6aec. Alle375 Manifestdateien wurden unmittelbar vor und nach dem Lauf unabhängig gehasht und sind unverändert. Die vorhandene F16-Dokumentation bindet diesen Consumer an f8e2bdc4933327ce2334ccb5450cb431273ef5bd; deren Sourcevergleich wurde nicht wiederholt.

Eigener Container aus dem vorhandenen fastra-linux-git-check:local, UID1000, Netzwerk none, eigenes Xvfb/DBus/HOME/XDG, ausschließlich read-only Produktmounts. Kein Source-/Hostdisplaymount, keine Repoänderung, kein Neubau und keine geänderten JSON-/Quellargumente. Pandoc3.1.3 einschließlich der bereits bekannten Daten und zwei Bibliotheken kam unverändert aus pmt-linux-backend-test:latest ausschließlich in den eigenen Container; kein weiterer Umgebungsausbau.

## Tatsächlich ausgeführte Fälle

- `normal.enex` aus der benannten enex-pdf-positive-Lieferung: Prepare im echten Importdialog meldet „The Python GI Poppler/Cairo PDF attachment validation backend is not available in this build.“ Adopt bleibt deaktiviert; kein Ergebnisordner.
- `encrypted.enex` aus derselben Lieferung: dieselbe kontrollierte MissingBackend-Diagnose, gesperrte Adoption und kein Ergebnisordner. Der fehlende Backend lässt hier keine Aussage zur späteren Verschlüsselungsdiagnose zu.
- Unverändertes `picture.docx` aus der0.41.14-Lieferung: Prepare zeigt zwei Dateien mit139Byte Markdown und1739Byte PNG. Vor Adopt kein veröffentlichtes Ziel. Echter Adopt öffnet picture.md. Echte Markdownvorschau zeigt Titel, Unicode, tatsächliches PNG und Beta23-Tabelle. Vollständiger Ergebnisbaum ist bytegleich zur0.41.14-Baseline, PNG161e77431664be88483d7fef7bdd0123c9ed53318cfc9d1c4fa84af80ea2ab28.

Alle drei Quellhashes und die CLI waren vor/nach unverändert. Keine Stagingreste. `verified.json` enthält die unabhängigen Vergleiche; PNGs wurden visuell angesehen.

## Umgebungslücke

Das vorhandene git-check-Image und das gezielt geprüfte fastra-linux-print-check besitzen kein PythonGI. Das gezielt geprüfte pmt-linux-gui-test besitzt GI/Poppler/Cairo, aber keine WebKitGTK6-Runtime für Fastra. Nach zwei ungeeigneten Imagewegen wurde entsprechend Auftrag keine Testumgebung aufgebaut. Die gesonderten direkten 0.41.15-PDF-CLI-Positivfälle stehen im übergeordneten Produktbericht; sie ersetzen keinen GUI-Positivfall.

## Reproduktion und Cleanup

Der Ablauf entspricht der vorhandenen0.41.14-REPRO mit unverändertem start.sh. Nur drei Quellen einsetzen: normal.enex, encrypted.enex, picture.docx. Tool `/work/producer/poormans-text`, Destination `/work/output`, jeweilige Ergebnisnamen normal/encrypted/docx. Echte Prepare/Adopt-Buttons wie zuvor bedienen. Das Rootlauncher bleibt unverändert und verweist über den privaten Symlink `.build/linux-runtime → /pmt` auf die read-only0.41.15-Runtime. Die Inputhashes stehen in before.json. Positivvergleich: output/docx vollständig mit der vorherigen0.41.14-Lieferung vergleichen.

Eigener Container gestoppt/entfernt, große Tool-/Workkopie und Privatprofile entfernt. Nur kleine Ergebnisbelege bleiben. Nächste Referenzprüfung2026-12-05; entbehrliche Daten spätestens30Tage nach Abnahme entfernen. Screenshots privat halten.
