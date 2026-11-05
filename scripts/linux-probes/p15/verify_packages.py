#!/usr/bin/env python3
"""Prüft drei lokale Paketformate, verschobene Laufzeit und Publikationsfehler."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--packages', required=True, type=Path)
parser.add_argument('--packager', required=True, type=Path)
parser.add_argument('--evidence', type=Path)
parser.add_argument('--build-umask', choices=['022', '077'], help='Nur mit unabhängig protokolliertem Paketbau angeben')
args = parser.parse_args()
packages = args.packages.resolve()
packager = args.packager.resolve()
files = sorted(p for p in packages.iterdir() if not p.name.endswith('.sha256'))
assert len(files) == 3
records = {}
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
before = {p.name: digest(p) for p in packages.iterdir()}
for package in files:
    expected = package.with_name(package.name + '.sha256').read_text().split()[0]
    assert digest(package) == expected
    assert stat.S_IMODE(package.stat().st_mode) == 0o644
    with tempfile.TemporaryDirectory(prefix='pmt-package-extract-') as temporary:
        root = Path(temporary)
        destination = root / 'Paket ü'
        destination.mkdir()
        if package.suffix == '.deb':
            subprocess.run(['dpkg-deb', '--extract', str(package), str(destination)], check=True)
        else:
            subprocess.run(['tar', '--zstd', '--same-permissions', '-xf', str(package), '-C', str(destination)], check=True)
        for directory in ['usr', 'usr/bin', 'usr/lib', 'usr/share', 'usr/share/doc']:
            assert stat.S_IMODE((destination / directory).stat().st_mode) == 0o755
        packaged_runtime = destination / 'usr/lib/poormans-text'
        assert not (packaged_runtime / 'structured-ocr').exists(), 'Optional models leaked into base package'
        assert not list(packaged_runtime.glob('ui-old-*')), 'Retained GUI backups leaked into package'
        launcher = destination / 'usr/bin/poormans-text'
        assert stat.S_IMODE(launcher.stat().st_mode) == 0o755
        version = subprocess.check_output([str(launcher), '--version'], text=True).strip()
        source = root / 'Quelle ä.csv'
        source.write_text('Name,Value\nÄpfel,12\nBirnen,7\n')
        original = digest(source)
        output = root / 'Ergebnis ü'
        p = subprocess.run([str(launcher), '--json', '--report', '--output', str(output), str(source)], capture_output=True, text=True, timeout=30)
        assert p.returncode == 0, (package.name, p.stdout, p.stderr)
        result = json.loads(p.stdout)
        text = Path(result['markdownFile']).read_text()
        assert 'Äpfel' in text and 'Birnen' in text and digest(source) == original
        for entry in result['outputFiles']:
            assert digest(output / entry['path']) == entry['sha256']
        records[package.name] = {'sha256': expected, 'version': version, 'publicFileModes': True,
                                  'relocatedUnicodeLauncher': True, 'actualCSVConversion': True,
                                  'sourceAndOutputHashes': True}
collision = subprocess.run([str(packager), '--no-build', '--format', 'all', '--output-directory', str(packages)], capture_output=True, text=True, timeout=15)
assert collision.returncode == 73
assert before == {p.name: digest(p) for p in packages.iterdir()}
with tempfile.TemporaryDirectory(prefix='pmt-package-parent-') as temporary:
    root = Path(temporary)
    destination = root / 'target'
    destination.mkdir()
    alias = root / 'alias'
    alias.symlink_to(destination, target_is_directory=True)
    p = subprocess.run([str(packager), '--no-build', '--format', 'tar', '--output-directory', str(alias)], capture_output=True, text=True, timeout=15)
    assert p.returncode != 0 and list(destination.iterdir()) == []
result = {'formats': records, 'buildUmask': args.build_umask, 'publicFileModesVerified': True, 'optionalModelRuntimeExcluded': True,
          'existingPackagesUnchangedOnCollision73': True,
          'symlinkParentRejectedWithoutOutput': True}
if args.evidence:
    args.evidence.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
print(json.dumps(result, indent=2, ensure_ascii=False))
