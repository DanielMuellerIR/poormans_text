#!/usr/bin/env python3
"""Läuft nur in einem entbehrlichen Container; installiert dort zwei lokale DEBs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--old', type=Path, required=True)
parser.add_argument('--new', type=Path, required=True)
args = parser.parse_args()
if not Path('/.dockerenv').exists() or os.getuid() != 0:
    raise SystemExit('This destructive package lifecycle probe requires a disposable root Docker container.')
assert shutil.which('swift') is None
root = Path('/tmp/PMT Paketprobe ü')
root.mkdir()
root.chmod(0o777)
profiles = root / 'Profile'
source = root / 'Quelle ä.csv'
source.write_text('Name,Count\nÄpfel,12\nBirnen,7\n')
before = hashlib.sha256(source.read_bytes()).hexdigest()
records = []

def cli(*flags):
    result = subprocess.run(['setpriv', '--reuid=65534', '--regid=65534', '--clear-groups',
                             '/usr/bin/poormans-text', *map(str, flags)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (flags, result.stdout, result.stderr)
    return json.loads(result.stdout)

for index, package in enumerate([args.old, args.new]):
    subprocess.run(['dpkg', '--install', str(package)], check=True)
    response = cli('--json', '--report', '--output', root / f'Ergebnis {index}', source)
    markdown = Path(response['markdownFile']).read_text()
    assert 'Äpfel' in markdown and 'Birnen' in markdown and '12' in markdown and '7' in markdown
    if index == 0:
        cli('--json', '--profiles-directory', profiles, '--save-profile', 'Behalten ü', '--frontmatter')
        profile_bytes = {p.name: p.read_bytes() for p in profiles.iterdir()}
    assert {p.name: p.read_bytes() for p in profiles.iterdir()} == profile_bytes
    assert any(p['name'] == 'Behalten ü' for p in cli('--json', '--profiles-directory', profiles, '--list-profiles')['profiles'])
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before
    records.append({'version': response['version'], 'conversionAsUnprivilegedUser': True,
                    'unicodePath': True, 'profilePreserved': True, 'sourceUnchanged': True})
subprocess.run(['dpkg', '--remove', 'poormans-text'], check=True)
assert not Path('/usr/bin/poormans-text').exists()
assert not Path('/usr/lib/poormans-text').exists()
assert {p.name: p.read_bytes() for p in profiles.iterdir()} == profile_bytes
assert hashlib.sha256(source.read_bytes()).hexdigest() == before
print(json.dumps({'noSwiftSDK': True, 'network': 'none', 'installs': records,
                  'removedPackageFiles': True, 'userDataPreservedAfterRemoval': True}, ensure_ascii=False, indent=2))
