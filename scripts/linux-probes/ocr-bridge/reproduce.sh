#!/bin/sh
set -eu
work=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=swift:6.2.1-noble
# Der lokale Image-Pin ist im Befund dokumentiert; niemals implizit pullen.
test "$(docker image inspect --format '{{.Id}}' "$image")" = sha256:675d824f661891504d6957578068a7a28e588fb75fe7fd73e041f2f1ab72a359
cpu=${PMT_PROBE_CPU:-$(python3 -c 'import os;print(min(os.sched_getaffinity(0)))')}
docker run --rm --pull never --network none --cpuset-cpus "$cpu" -v "$work:/work" -w /work "$image" bash -c '
set -eu
swiftc -parse-as-library -swift-version 6 probe/matrix.swift -o probe/matrix
for mode in immediate callback sleep; do
 echo MODE=$mode
 code=0
 timeout 5 probe/matrix 24 "$mode" || code=$?
 echo EXIT=$code
 if [ "$mode" = sleep ]; then test "$code" = 124; else test "$code" = 0; fi
done
swiftc -parse-as-library -swift-version 6 probe/gate.swift -o probe/gate
timeout 8 probe/gate 24 callback
cd minimal
timeout 60 swift test --jobs 2
'
