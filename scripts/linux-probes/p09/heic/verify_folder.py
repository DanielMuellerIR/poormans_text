"""Echter Mischordnerimport darf fehlende optionale HEIC-Decoder nicht verschweigen."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', type=Path, required=True)
parser.add_argument('--fixtures', type=Path, required=True)
args = parser.parse_args()
catalog = subprocess.run([str(args.cli), '--json', '--formats'], capture_output=True, timeout=40, check=True)
images = [entry for entry in json.loads(catalog.stdout)['formats'] if entry['format'] == 'image']
assert len(images) == 1 and images[0]['available'] and 'png' in images[0]['extensions']
available = 'heic' in images[0]['extensions']

with tempfile.TemporaryDirectory(prefix='pmt-heic-folder-') as temporary:
    root = Path(temporary)
    source = root / 'input'
    source.mkdir()
    shutil.copyfile(args.fixtures / 'single.heic', source / 'photo.heic')
    shutil.copyfile(args.fixtures / 'single-1.png', source / 'scan.png')
    before = {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in source.iterdir()}
    output = root / 'output'
    process = subprocess.run([str(args.cli), '--json', '--image-ocr', 'off', '--output', str(output), '--', str(source)],
                             capture_output=True, timeout=40)
    assert process.returncode == (0 if available else 69), process.stdout
    response = json.loads(process.stdout)
    results = {Path(entry['input']).name: entry for entry in response['results']}
    assert set(results) == {'photo.heic', 'scan.png'}, response
    assert results['scan.png']['ok']
    assert results['photo.heic']['ok'] == available
    for file in source.iterdir():
        assert hashlib.sha256(file.read_bytes()).hexdigest() == before[file.name]
    if not available:
        assert 'backend is not available' in results['photo.heic']['error']
        assert not (output / 'photo-markdown').exists()
    print(json.dumps({'exit': process.returncode, 'heicAdvertised': available,
                      'imageRows': len(images), 'pngConverted': True,
                      'heicIncluded': True, 'heicConverted': available,
                      'sourceHashesUnchanged': True}))
