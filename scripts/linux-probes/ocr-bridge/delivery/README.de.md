# Native Mac-Regression

`prepare_payload.py REPO NEUES_PAYLOAD` friert einen Hash-gebundenen Snapshot
inklusive benötigter Rootskripte und Workflowfixtures ein. Ohne `--candidate`
verändert er keine Quellen. Der tatsächliche aktuelle Runner prüft beide
arm64-XCTest-Bundles und führt die vollständige Suite ohne Skipfilter aus.
StructuredOCR ist Bestandteil dieser Suite. Eine gesonderte Sleep-/Callback-
Matrix wird damit nicht erneut ausgeführt; ihre Quellen bleiben unter `probe/`.

Nur mit erteilter Remoteautorisierung: Payload und Runner in einer neuen eigenen
`/private/tmp/pmt-ocr-mac-*`-Wurzel ablegen. SSH-stdout des Runneraufrufs direkt
in `LOCAL_WORK/live-events.jsonl` sichern. `decode_events.py` nach LOCAL_WORK
kopieren und dort ausführen. Seine Logs müssen nach Proofabholung bytegleich
sein. Anschließend erst `cleanup.py REMOTE_ROOT`, danach `cleanup_proof.py`
über SSH-stdin mit PROOF, EXPECTED_SHA256 und REMOTE_ROOT aufrufen.

Der Runner begrenzt die Arbeit auf3600s einschließlich180s Cleanupreserve,
isoliert Home/Preferences/Caches und bindet seine Wachhaltung an den Prozess.
Er aktiviert keine App und installiert nichts. Der geprüfte Lauf und seine
Grenzen stehen in `docs/linux-port/P16-04117/README.md`.
