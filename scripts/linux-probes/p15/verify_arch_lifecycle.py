#!/usr/bin/env python3
"""ALPM-Dateitransaktion in privater Wurzel; keine Hostdatenbank oder Downloads."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package', required=True, type=Path)
parser.add_argument('--evidence', type=Path)
args = parser.parse_args()
package = args.package.resolve()
assert package.is_file()
expected = package.with_name(package.name + '.sha256').read_text().split()[0]
assert hashlib.sha256(package.read_bytes()).hexdigest() == expected
with tempfile.TemporaryDirectory(prefix='pmt-arch-lifecycle-') as temporary:
    root = Path(temporary)
    for name in ['filesystem', 'database', 'cache', 'gpg', 'empty-hooks']:
        (root / name).mkdir()
    config = root / 'pacman.conf'
    config.write_text('[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\nLocalFileSigLevel = Optional\n')
    sandbox = ['/usr/bin/bwrap', '--unshare-all', '--die-with-parent', '--new-session',
               '--uid', '0', '--gid', '0', '--ro-bind', '/', '/', '--bind', str(root), str(root),
               '--ro-bind', str(root / 'empty-hooks'), '/usr/share/libalpm/hooks',
               '--proc', '/proc', '--dev', '/dev']
    options = ['/usr/bin/pacman', '--config', str(config), '--root', str(root / 'filesystem'),
               '--dbpath', str(root / 'database'), '--cachedir', str(root / 'cache'),
               '--logfile', str(root / 'transaction.log'), '--gpgdir', str(root / 'gpg'),
               '--hookdir', str(root / 'empty-hooks'), '--noconfirm']
    def pacman(*flags, expected=0):
        p = subprocess.run(sandbox + options + list(flags), capture_output=True, text=True, timeout=45)
        assert p.returncode == expected, (flags, p.returncode, p.stdout, p.stderr)
        return p.stdout
    pacman('-U', '--nodeps', '--nodeps', '--noscriptlet', str(package))
    installed = pacman('-Q', 'poormans-text').strip()
    pacman('-Qk', 'poormans-text')
    filesystem = root / 'filesystem'
    launcher = filesystem / 'usr/bin/poormans-text'
    assert launcher.stat().st_mode & 0o777 == 0o755
    for directory in [filesystem / 'usr', filesystem / 'usr/bin', filesystem / 'usr/lib', filesystem / 'usr/share/doc']:
        assert directory.stat().st_mode & 0o777 == 0o755
    assert shutil.which('swift') is None
    source = root / 'Quelle ü.csv'
    original = 'Name,Value\nÄpfel,12\n'.encode()
    source.write_bytes(original)
    p = subprocess.run([str(launcher), '--json', '--report', '--output', str(root / 'Ergebnis ü'), str(source)], capture_output=True, text=True, timeout=30)
    assert p.returncode == 0, (p.stdout, p.stderr)
    response = json.loads(p.stdout)
    assert 'Äpfel' in Path(response['markdownFile']).read_text()
    assert source.read_bytes() == original
    for entry in response['outputFiles']:
        assert hashlib.sha256((root / 'Ergebnis ü' / entry['path']).read_bytes()).hexdigest() == entry['sha256']
    pacman('-R', '--noscriptlet', 'poormans-text')
    pacman('-Q', 'poormans-text', expected=1)
    assert not launcher.exists() and not (filesystem / 'usr/lib/poormans-text').exists()
    assert source.read_bytes() == original
    result = {'installed': installed, 'packageSHA256': expected, 'actualALPMInstallRemove': True,
              'privateDatabaseAndRoot': True, 'network': 'none', 'globalHooksMasked': True,
              'noSwiftSDK': True, 'unicodeRelocatedLauncherAndConversion': True,
              'sourceAndOutputHashes': True, 'removedPackageFiles': True,
              'dependencyResolutionVerified': False, 'freshArchChrootVerified': False}
    if args.evidence:
        args.evidence.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
