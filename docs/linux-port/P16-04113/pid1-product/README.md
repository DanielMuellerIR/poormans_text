# Echter CLI-PID1-Produktfall 0.41.13

2026-11-05: bestanden. Die unveränderte finale Swift-CLI lief direkt per
Docker-Entrypoint als Namespace-PID1, ohne --init und ohne vorgeschaltete Shell.
`pid1.json` stammt aus einem während der Konvertierung ausgeführten docker exec
mit /proc/1/status, exe und cmdline: Name poormans-text, PID1/PPID0, UID1000.
Das vorhandene Noble-Backendimage enthält keinen Swift-SDK (wirklich geprüft).

CLI 26470eaf5d0b474e7f164882683b339ffc63b75d20a3ecdd6856729883f8f460
Guard cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520
CPMTLinux/process.c 56066ab58b87fe3f614ccac00a20caa0005872081f29204a385ef57990dddc9d

CLIhash vor/nach Lauf gleich. bin und lib waren getrennt read-only eingebunden,
Pandoc 3.1.3 ebenfalls explizit read-only, einzig der eigene Workbereich schreibbar.
Kein Download, keine Runtimekopie und keine Repoänderung.

Das durch fixtures.py erzeugte echte RTF nutzt CP1252 plus RTF-Unicodeescapes.
Der produktive RTF-Adapter rief das reale Pandoc über den echten ProcessRunner
auf. Exit 0/ok=true, echte Veröffentlichung. verify.py prüft unabhängig alle 12000
geordneten Absätze einschließlich Grüße, SourceIdentity und unveränderte
Originalbytes sowie byteCount/SHA256 jeder gemeldeten Ausgabedatei. Keine
Capturedateien im Workbereich übrig. Rohes Fehler-/Ergebnis-JSON bleibt erhalten.
Der erste Aufruf verwendete irrtümlich --process-timeout und wurde mit 64
abgewiesen; der echte positive Lauf nutzt die dokumentierte Option --timeout 60.

Vor Containerentfernung: Status exited, Running=false, PID0, ExitCode0,
OOMKilled=false, Error leer. Der private PIDnamespace war beendet; keine
lebenden Prozesse dieses Containers. Dockerlauf von 05:52:26.104787904Z
bis 05:52:28.439249137Z. Eigener Container und kompletter temporärer Work-/
Ausgabe-/Profilbereich wurden nach Sicherung kleiner Belege entfernt.
Die 17 Runnerverlustregressionen sind eine getrennte Produktprüfung.

Vorhandenes Image pmt-linux-backend-test:latest:
sha256:503d26e7ff355675abf87b8a914f26f4698a40e813c08195c835d57b537f66c0

## Generischer Wiederholungsweg

Eigenes WORK mit UID1000-schreibbaren Rechten erstellen; fixtures.py darauf
anwenden. RUNTIME benennt die stillstehende passende Runtime, PANDOC die bewusst
gewählte lokale Pandocdatei. Kein Initargument verwenden:

```sh
docker run -d --name "$CONTAINER" --network none \
 --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
 --user 1000:1000 -v "$WORK:/work" \
 -v "$RUNTIME/bin:/runtime/bin:ro" -v "$RUNTIME/lib:/runtime/lib:ro" \
 -v "$PANDOC:/usr/bin/pandoc:ro" -e LD_LIBRARY_PATH=/runtime/lib \
 -e HOME=/work -e TMPDIR=/work -e LANG=C.UTF-8 \
 --entrypoint /runtime/bin/poormans-text pmt-linux-backend-test:latest \
 --json --report --timeout 60 --output /work/result -- /work/source.rtf
docker exec "$CONTAINER" cat /proc/1/status
docker wait "$CONTAINER"
docker logs "$CONTAINER" > "$RESPONSE"
python3 verify.py --work "$WORK" --response "$RESPONSE" --evidence "$EVIDENCE"
docker rm "$CONTAINER"
```

Für die während des etwa 2,3 s-Laufs nötige Beobachtung docker exec unmittelbar
nach Start ausführen; diese Probe hat zusätzlich exe und cmdline geprüft.
Kein SDKprozess oder Fixturegenerator ersetzt den beobachteten Produkt-PID1.
