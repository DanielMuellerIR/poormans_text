# OCRAsyncBridge: lokalisierte Blockade und nativer Prüfkandidat

Read-only-Diagnose 2026-11-05. Keine Rootdatei verändert, kein Git, kein SSH, kein erneuter Maczugriff. Die alte Macfreigabe wurde nicht als fortbestehend angenommen. Der native Lauf ist vorbereitet und ausdrücklich NICHT ausgeführt.

## Befund

Der bekannte Test blockiert 24 kooperative Caller in `OCRAsyncBridge.run` und verwendet innerhalb aller asynchronen Operationen `Task.sleep`. Die gespeicherte Macprobe zeigt den eigenen Thread-Executor ohne wartende Jobs in DocumentOCR.swift97; die Caller hängen an dessen Semaphore. Der Test ruft weder Vision noch OCRConcurrencyGate auf.

Die unveränderte Brücke wurde mechanisch in eine abhängigkeitenfreie Foundation-Probe übernommen (Mac-Plattformklammer/Verfügbarkeit entfernt und allein das Linux-Autoreleasepool-Noop angepasst). Im lokalen Swift6.2.1-Noblecontainer mit exakt einer sichtbaren CPU ist dieselbe24Task-Blockade reproduziert:

- sofortige Antwort: Exit0, Summe276;
- eigener Thread → CheckedContinuation als externer Callback: Exit0, Summe276;
- ursprüngliches Task.sleep2ms: äußerer5s-Abbruch124;
- ursprüngliches OCRConcurrencyGate mit24externen Callbacks: Exit0, Summe276.

Ohne CPU-Begrenzung liefen24 und512 ursprünglicheSleep-Aufrufe durch. Der Fehler hängt also von Poolkapazität ab; eine längere Testfrist ist keine Korrektur. libdispatch-STRICT allein reproduzierte ihn hier nicht zuverlässig.

Die Primärquelle erklärt den Mechanismus: TaskSleep.swift erstellt einen zusätzlichen Wake-Task und fällt ohne SchedulableExecutor auf `_enqueueJobGlobalWithDelay` zurück. Die TaskExecutor-Präferenz deckt diesen Timerjob nicht allgemein ab. Sämtliche Caller blockieren den Pool, der diesen Wake-Task noch ausführen muss. Das erklärt die lokale A/B-Reproduktion und passt zur alten Macstackprobe; die native A/B-Bestätigung steht bis zur erneuten Freigabe aus.

Primärquellen:
- https://raw.githubusercontent.com/swiftlang/swift/swift-6.2.1-RELEASE/stdlib/public/Concurrency/TaskSleep.swift (Zeilen239–264)
- https://raw.githubusercontent.com/swiftlang/swift/swift-6.2.1-RELEASE/stdlib/public/Concurrency/Executor.swift (TaskExecutor versus internes SchedulableExecutor)
- https://forums.swift.org/t/task-executor-preference-and-deterministic-scheduling/72448 (Swift-Concurrency-Implementierer bestätigen dieselbe bekannte Einschränkung)

## Kleinster Kandidat und Grenze

`candidate.patch` korrigiert den Test-Callback und die zu weit gefasste Brückenbeschreibung. Keine Produktlogik und keine API geändert. Der24Task-Kontexttest bleibt aktiv und prüft die Bindung jetzt vor UND nach einer wirklichen asynchronen externen Fortsetzung. Zusätzlich prüft ein24Task-Gatetest, dass höchstens eine Recognition aktiv ist und alle24 abschließen. Der bisherige Abbruchtest bleibt unverändert.

Im minimalen SwiftPM-Adapter bestanden diese drei tatsächlichen XCTestfälle auf einer CPU:3ausgeführt,0Fehler,0Skips. Die unveränderte generische Brücke und das originale Gate werden verwendet; nur der für diesen kleinen Build erforderliche Cancellation-/TaskLocal-Kontext wird eng nachgebildet. Das ist keine Kompilier-/Laufabnahme der vollständigen Macdateien oder von Vision.

Dies ist eine Korrektur des ungeeigneten Testmodells, KEIN allgemeiner Produktfix für beliebige asynchrone Arbeit unter vollständiger Poolblockierung. Eine synchrone Brücke kann nicht zusichern, dass beliebige globale Timer, unstrukturierte Tasks oder Actorarbeit unabhängig vom vollständig blockierten globalen Pool fortschreiten. Soll die öffentliche synchrone Konvertierung dies für beliebige kooperative Caller garantieren, braucht die aufrufende Seite eine echte asynchrone/offloadende Grenze; zusätzliche Semaphore/Threads innerhalb dieser Brücke lösen das nicht. Ein solcher API-Umbau wurde nicht vorgenommen. Der produktive Gate-Timer wurde nicht ohne belegten eigenen Fehler geändert: mit externem Callback besteht die tatsächliche Gateprobe bereits.

## Ausführbare Nachweise und Payload

`reproduce.sh` führt die oben genannte Erwartungsmatrix und3XCTestfälle ohne Netz auf dem vorhandenen offiziellen Dockerimage aus. `PMT_PROBE_CPU` kann explizit einen erlaubten Host-CPUindex wählen. Verwendetes lokales Image swift:6.2.1-noble: sha256:675d824f661891504d6957578068a7a28e588fb75fe7fd73e041f2f1ab72a359. Keine Downloads oder Hostpaketänderungen.

`native-payload/` ist der prüfbare, noch nicht übertragene aktuelle Quellsnapshot:569Dateien, ausschließlich zwei Kandidatendeltas. manifest.json bindet ursprüngliche und tatsächliche Dateihashes. Quellarchiv SHA256293bbaea8fcf378ff63f49e21e24f98a21085985b24d3b108842c25b79ab2b99. Rootsource meldete beim Snapshot0.41.16; keine Versionsänderung durch diesen Auftrag.

`delivery/prepare_payload.py REPO NEW_OUTPUT --candidate` erzeugt einen frischen Snapshot und prüft während der Erstellung, dass alle ursprünglichen Dateien stabil blieben. Ohne Flag entsteht eine reine Baseline. Sources/Tests/App/scripts und die unmittelbar benötigten öffentlichen Docs/Doclingreferenzen sind enthalten, keine Git-/Buildcaches.

`delivery/mac_runner.py` beziehungsweise die Kopie im Payload:
- nur eigene /private/tmp/pmt-ocr-mac-*-Wurzel, Archiv-/Dateihashprüfung;
- privater HOME/CFFIXED_USER_HOME/TMPDIR/SwiftPM-/Modulcache/Preferences, vorhandene Sparkle-/Repository-Seeds ausschließlich lesend kopieren;
- native arm64-Matrix (originalerSleep und externerCallback), danach unveränderte vollständige StructuredOCRTests und gesamte Testsuite OHNE Skipfilter;
- kein Appstart, kein UI, kein Installieren/Notarisieren/globaler CLI-Pfad;
- maximal3600s inklusive120s Cleanupreserve; zusätzlicher eigener Watchdog und TERM/INT/HUP-Handler;
- Timeout/Abbruch nur eigene gestartete Prozessgruppen, TERM→KILL+wait; bei Timeout nur eigene zugeordnete XCTestprozesse kurz sampeln;
- Testexecutable separat lipoarm64 prüfen und SHA256 sichern, Quellhashes abschließend prüfen;
- auch bei Fehler eigener caffeinate/Prozesscleanup, kleines Ergebnisarchiv unter eindeutigem privaten Namen erzeugen, gesamten Arbeitsbaum mit gehaltenen DirectoryFDs/nofollow entfernen; Ergebnisarchive müssen nach Abholung separat entfernt werden.

Beide Python-Skripte wurden lokal py_compile-geprüft. Kein vollständiger nativer Lauf oder tatsächlicher Remote-Cleanup damit behauptet. Ununterbrechbare Kernel-I/O und SIGKILL des Runners können wie üblich kein Python-finally garantieren. Vor jeder Übertragung/Lauf ist erneuerte zeitliche Remoteautorisierung erforderlich. Die lokale kleine Lieferung bleibt zur Reviewabnahme erhalten; generierte Dockerbuildartefakte wurden entfernt.
