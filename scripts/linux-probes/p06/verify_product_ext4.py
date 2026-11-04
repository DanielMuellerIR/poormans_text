#!/usr/bin/env python3
"""Echter Produktkonverter auf dem begrenzten, ausschließlich eigenen ext4-Image."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

phase, root = sys.argv[1], Path(sys.argv[2])
source = root / 'source.csv'
original = b'Name,Value\nEXT4TOKEN,42\n'
sentinel = root / 'existing' / 'sentinel'


def convert(target):
    response = subprocess.run(
        ['/product/bin/poormans-text', '--json', '--report', '--source-map',
         '--output', str(root / target), '--', str(source)],
        capture_output=True, timeout=30,
    )
    return response.returncode, json.loads(response.stdout)


if phase == 'before':
    source.write_bytes(original)
    sentinel.parent.mkdir()
    sentinel.write_bytes(b'EXISTINGTOKEN')

if phase in ('before', 'recovered'):
    code, result = convert('success-' + phase)
    assert code == 0 and result['ok'], (code, result)
    output = root / ('success-' + phase)
    text = (output / 'source.md').read_text()
    assert text.count('EXT4TOKEN') == 1 and text.count('42') == 1
    report = json.loads((output / 'conversion-report.json').read_text())
    assert report['source']['sha256'] == hashlib.sha256(original).hexdigest()
    assert len(result['sourceMappings']) == 4
elif phase == 'full':
    code, result = convert('must-not-publish')
    assert code != 0 and not result['ok'], (code, result)
    assert 'space' in result['error'].lower(), result
    assert not (root / 'must-not-publish').exists()
    assert not list(root.glob('.poormans-text-*.tmp'))
else:
    raise AssertionError(phase)

collision_code, collision = convert('existing')
assert collision_code != 0 and not collision['ok']
assert sentinel.read_bytes() == b'EXISTINGTOKEN'
assert source.read_bytes() == original
record = {'phase': phase, 'nonRootUID': os.geteuid(), 'passed': True,
          'sourceUnchanged': True, 'existingOutputUnchanged': True,
          'availableBlocks': os.statvfs(root).f_bavail}
if phase == 'full':
    record.update({'enospcObserved': True, 'noNewOutput': True,
                   'noStagingLeft': True, 'failureExit': code})
Path('/results/evidence/' + phase + '.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record), flush=True)
