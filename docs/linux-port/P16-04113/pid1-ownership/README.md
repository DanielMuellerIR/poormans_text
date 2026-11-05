# PID1-Abstammungsprüfung

2026-11-05: bestanden. Die wirkliche C-Funktion aus dem Linux-Produkt wurde
unverändert read-only im vorhandenen Nobleimage eingeblendet, mit Clang gebaut
und als Namespace-PID1/UID1000 ohne --init oder Shell ausgeführt.

Produktquelle process.c SHA256:
56066ab58b87fe3f614ccac00a20caa0005872081f29204a385ef57990dddc9d

PMTProcess.h SHA256:
3222f2291995bde0151ac2c5739990311ded10aa7be81a8cf3f24370abf2d9a7

Image swift:6.2.1-noble:
sha256:675d824f661891504d6957578068a7a28e588fb75fe7fd73e041f2f1ab72a359

result.json ist die tatsächliche stdout-Antwort. Eigener direkter Kindprozess,
Enkel, dessen Zwischenvorfahr und PID1 selbst akzeptiert. Zwei Geschwister mit
ZielA/behauptetem VorfahrB werden 100-mal mit ESRCH abgewiesen; alle Ziele sind
danach lebendig. Keine Signale auf abgewiesene pidfds. Vor/nach 100 Iterationen
keine FD-Zunahme; nach ausdrücklichem Beenden werden pidfds ready, alle drei
Kinder eingesammelt und sämtliche gehaltenen Deskriptoren geschlossen.
FD-Baseline 4 und Endwert 4 enthalten jeweils den kurz geöffneten proc-Verzeichnis-
leser. Der abgeschlossene eigene Testcontainer und das eigene Testbinary wurden
nach Belegsicherung entfernt; keine Downloads oder Rootrepoänderungen.

Grenze: C-Besitzprüfung, kein Swift-CLI-PID1-Produkttest und keine neue Runner-
verlustregression. Diese getrennten Produktprüfungen übernimmt der Hauptlauf.
Der erste Buildaufruf mit cc scheiterte, weil dieses Image nur Clang bereitstellt;
der zweite nutzte den vorhandenen Clang, ohne Installation oder Toolersatz.

Reproduktion mit vorhandenen Quellen und Image, eigener Probeordner:

```sh
docker run --rm --network none --user 1000:1000 \
  -v "$PROBE:/probe" -v "$REPO/Sources/CPMTLinux:/input:ro" \
  swift:6.2.1-noble clang -std=c11 -Wall -Wextra -Werror -pthread \
  -I/input/include /probe/probe.c /input/process.c -o /probe/pid1-probe
docker run --rm --network none --user 1000:1000 \
  -v "$PROBE:/probe" --entrypoint /probe/pid1-probe swift:6.2.1-noble
```

probe.c vorher aus diesem Ordner in den eigenen PROBE kopieren. Die Probe
verlangt absichtlich getpid()==1 und beendet ihre eigenen Kinder vollständig.
