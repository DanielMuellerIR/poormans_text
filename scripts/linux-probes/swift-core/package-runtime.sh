#!/bin/bash
set -euo pipefail
# Im Probe-Container unter /probe ausführen; keine Installation auf dem Host.
mkdir -p runtime/lib runtime/bin runtime/share
cp .build/debug/pmt-probe runtime/
ldd .build/debug/pmt-probe > ldd.txt
awk '/=> \/usr\/lib\/swift\// {print $3}' ldd.txt | while IFS= read -r lib; do cp -L "$lib" runtime/lib/; done
for name in libxml2.so.2 libicuuc.so.74 libicudata.so.74 libyaml-0.so.2 liblua5.4.so.0; do cp -L "/lib/x86_64-linux-gnu/$name" runtime/lib/; done
cp /usr/bin/pandoc runtime/bin/pandoc.real
cp -R /usr/share/pandoc runtime/share/
cat > runtime/bin/pandoc <<'WRAPPER'
#!/bin/sh
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "$base/bin/pandoc.real" --data-dir="$base/share/pandoc/data" "$@"
WRAPPER
chmod +x runtime/bin/pandoc
ldd /usr/bin/pandoc > pandoc-ldd.txt
dpkg-query -W libxml2 libicu74 zlib1g liblzma5 liblua5.4-0 libyaml-0-2 pandoc > system-dependencies.txt
