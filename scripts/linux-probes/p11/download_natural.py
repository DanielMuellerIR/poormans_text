#!/usr/bin/env python3
"""Expliziter Download dreier fixierter öffentlicher P11-PDFs; kein Produktlauf."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('new_directory', type=Path)
    args = parser.parse_args()
    evidence = Path(__file__).resolve().parents[3] / 'docs/linux-port/P11-NATURAL-EVIDENCE'
    manifest = json.loads((evidence / 'manifest.json').read_text())
    documents = manifest['documents']
    prefix = 'https://huggingface.co/datasets/upstage/dp-bench/resolve/' + manifest['revision'] + '/dataset/pdfs/'
    if len(documents) != 3 or sum(x['bytes'] for x in documents) >= 10_000_000:
        raise ValueError('Invalid corpus size')
    for item in documents:
        if Path(item['name']).name != item['name'] or item['url'] != prefix + item['name']:
            raise ValueError('Unexpected corpus URL or name')
    root = args.new_directory.expanduser().absolute()
    root.mkdir(mode=0o700)  # Existierende Dateien/Verzeichnisse niemals überschreiben.
    root = root.resolve()
    completed = []
    for item in documents:
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'PMT-explicit-P11-fixture-download'})
        with urllib.request.urlopen(request, timeout=30) as response:
            if not response.geturl().startswith('https://'):
                raise ValueError('Insecure corpus redirect')
            data = response.read(item['bytes'] + 1)
        if len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('Corpus byte count or SHA256 mismatch: ' + item['name'])
        if not data.startswith(b'%PDF-'):
            raise ValueError('Corpus response is not a PDF')
        with (root / item['name']).open('xb') as target:
            target.write(data)
        completed.append({'name': item['name'], 'bytes': len(data), 'sha256': item['sha256']})
    (root / 'download-receipt.json').write_text(json.dumps(completed, indent=2) + '\n')
    print(root)


if __name__ == '__main__':
    main()
