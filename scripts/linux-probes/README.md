# Isolierte Entscheidungstests P00–P04

Diese Skripte bauen keine Linux-Produktversion und ändern weder Package.swift
noch die Produktionsquellen. Entscheidung und offene Freigaben stehen in
[LINUX-DECISION.md](../../docs/LINUX-DECISION.md).

| Probe | Einstieg | Voraussetzung / Grenze |
| --- | --- | --- |
| P00 Mac-Referenz | `python3 contract/mac-baseline.py <PMT-Repo>` | Native Mac-CLI im Repo, Pandoc; eigenes temporäres Fixtureverzeichnis |
| P00 gespeicherte Belege | `python3 contract/verify-baseline.py <PMT-Repo>` | Python; prüft gespeicherte Hashes/UTF-8/Referenz-DOCX, keine neue Mac-Ausführung |
| P01 Consumer | `bash contract/run-consumer.sh <Fastra-Repo>` | Swift 6.2.1; Originalconsumer mit Framework-/Runner-Teststubs; Goldens bleiben read-only |
| P02 Kern | `python3 swift-core/prepare.py <PMT-Repo> <neues-Probeziel>`; `bash swift-core/build-and-run.sh <Probeziel>` | Docker; Netzwerk nur für Dependency-Setup, danach offline; Produktcode ausschließlich gelesen |
| P02 Ausgabeprüfung | `python3 swift-core/verify.py <Probeziel> <erzeugter-Ausgabeordner>` | Textzählung, Quellhash, PNG-Bytes; Ausgabeordner wird vom Lauf ausgegeben |
| P03 Dateisystem | `python3 safety.py --parent <beschreibbarer-Ordner>` | Linux/glibc, Nicht-root; legt nur eigenen Temp-Unterordner an; optional `--other-filesystem-parent` für EXDEV |
| P03 Originalrunner | `python3 foundation.py <neues-Probeziel>` | Kompilierung mit Swift 6.2.1; `Runner.swift Dependencies.swift main.swift`; Lauf nur mit frischem Arbeitsordner und äußerem Zeitlimit |
| P03 Besitzerverlust | `python3 parent_loss.py <kompilierter-Runner>` | Linux/proc/Subreaper; erwarteter negativer Sicherheitsbefund, eigene Kinder werden bereinigt |
| P04 Backends | `bash backends/run-probes.sh` | Abhängigkeiten in P04-Befund; neuer Tempordner, Bubblewrap muss Namespaces anlegen dürfen; kein Download |
| P04 Mac-Paar | `python3 backends/mac-run.py <Probeverzeichnis> <Mac-CLI>` | Identische Linux-Fixturebytes vorher übertragen; keine GUI-Aktivierung |

Im Container können die P01-Proben und Fastra read-only gemountet werden;
Build und Szenarien entstehen unter `/tmp`. Der P02-Generator wird mit seinem
vollständigen Patch ausgeliefert, ohne kopierte Swift-Quelldateien oder SDK.
Das Paket benötigt ausdrücklich mitgelieferte bzw. deklarierte Bibliotheken;
`run-runtime.sh` ist nur der untersuchte Launcher, kein Distributionsinstaller.

P03-Runnerbeispiel im erzeugten Probeverzeichnis:

```sh
swiftc -swift-version 6 Runner.swift Dependencies.swift main.swift -o runner
work=$(mktemp -d /tmp/pmt-runner-work.XXXXXX)
timeout --kill-after=2 15 ./runner "$work"
rmdir "$work"
```

Der Werkzeug-Sandbox ohne lokale Sockets fehlt Foundations Wakeup-Socket; dort
diese Prozessprobe nicht wiederholt starten. In den Zielsystemläufen sind keine
besonderen Rechte für Foundation erforderlich. Ein hart getöteter Runner kann
seine Capturedateien nicht selbst entfernen; die Negativprobe nutzt daher einen
eigenen Bereich und eine unabhängige Bereinigung.

Die P04-Proben erheben Beobachtungen einschließlich erwarteter Fehler und
Qualitätslücken. Ein Exit 0 des Probenablaufs bedeutet nicht Backendgleichheit.
Ein eigenes Ausgabeziel kann über `PMT_P04_ROOT` gesetzt werden und muss neu sein;
`PMT_P04_FONT` kann den Pfad zu DejaVuSans vorgeben. Keine fremden Dokumente oder
vorhandenen Ausgabeordner als Testdaten verwenden.

Referenzzweck: Wiederholung der Architekturentscheidung und Reproduktion der
offenen Vertrags-/Backend-/Sicherheitsbefunde. Bei der nächsten Entscheidung
vor P05 erneut prüfen; keine privaten Originale oder dauerhaften SDK-Kopien
aufbewahren. Die jetzigen Goldens dokumentieren PMT 0.41.7 und den in den
Befunden genannten Consumerstand. Fehlbeobachtungen im Consumer-Harness sind
bewusst als solche benannt und keine bestandene Produktabnahme.
