"""Bewusster Probeaufbau aus festen Wheels/Modellen; kein Produkt-Laufzeitcode."""
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

root = Path('/opt/docling')
root.mkdir()
wheels = root / 'wheels'
wheels.mkdir()
# Reserve für Distroarchive und Metadaten; der vorhandene Basislayer zählt separat.
used = 100 * 1024**2
cap = 1024**3

def download(url, path, size, digest):
    global used
    path.parent.mkdir(parents=True, exist_ok=True)
    actual = 0
    checksum = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=60) as response, path.open('xb') as output:
        while chunk := response.read(1024**2):
            if used + len(chunk) > cap:
                raise RuntimeError('1 GiB setup cap')
            output.write(chunk)
            checksum.update(chunk)
            used += len(chunk)
            actual += len(chunk)
    assert actual == size and checksum.hexdigest() == digest

for item in json.loads(Path('/setup/wheels.json').read_text()):
    from urllib.parse import urlparse, unquote
    name = unquote(urlparse(item['source']).path.rsplit('/', 1)[1])
    assert name.endswith('.whl') and '/' not in name
    download(item['source'], wheels / name, item['bytes'], item['sha256'])
for item in json.loads(Path('/setup/models.json').read_text()):
    url = f"https://huggingface.co/{item['repo']}/resolve/{item['revision']}/{item['file']}"
    download(url, root / 'models' / item['repo'].replace('/', '--') / item['file'], item['bytes'], item['sha256'])
subprocess.run(['/opt/probe/bin/pip', 'install', '--no-index', '--find-links', str(wheels), '--require-hashes', '-r', '/setup/requirements-resolved.txt'], check=True)
subprocess.run(['/opt/probe/bin/pip', 'check'], check=True)
