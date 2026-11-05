"""Reguläre Arch-Pakettransaktionen im frischen privaten Dockercontainer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--package', type=Path, required=True)
parser.add_argument('--previous-package', type=Path)
parser.add_argument('--heic-fixtures', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
args = parser.parse_args()
assert os.getuid() == 0 and Path('/.dockerenv').is_file(), 'Disposable Docker container only'
assert not Path('/usr/bin/poormans-text').exists(), 'Start with an uninstalled PMT package'
assert shutil.which('swift') is None


def run(command, expected=0, timeout=60):
    process = subprocess.run([str(value) for value in command], capture_output=True, timeout=timeout)
    assert process.returncode == expected, (command, process.returncode, process.stdout[-4096:], process.stderr[-4096:])
    return process.stdout


def package_identity(path):
    expected = path.with_name(path.name + '.sha256').read_text().split()[0]
    assert hashlib.sha256(path.read_bytes()).hexdigest() == expected
    identity = run(['pacman', '-Qp', path]).decode().strip().split()
    assert len(identity) == 2 and identity[0] == 'poormans-text'
    return {'version': identity[1], 'sha256': expected}


policy = run(['pacman-conf', 'SigLevel', 'LocalFileSigLevel'])
assert b'PackageRequired' in policy and b'PackageTrustedOnly' in policy
current = package_identity(args.package)
previous = package_identity(args.previous_package) if args.previous_package else None
if previous:
    assert int(run(['vercmp', current['version'], previous['version']]).decode()) > 0, 'Actual version upgrade required'
result = {'package': current, 'previousPackage': previous, 'freshArchContainer': True,
          'regularDependencyResolution': True, 'signaturePolicyUnchanged': True,
          'localPackageSignaturePolicy': 'Unmodified official-image LocalFileSigLevel Optional TrustedOnly; checksum-verified local PMT test artifact',
          'noSwiftSDK': True, 'transactions': []}

with tempfile.TemporaryDirectory(prefix='pmt-arch-package-') as temporary:
    root = Path(temporary)
    root.chmod(0o700)
    os.chown(root, 1000, 1000)
    environment = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'LANGUAGE': 'en'}
    for key, name in [('HOME', 'home'), ('TMPDIR', 'tmp'), ('XDG_RUNTIME_DIR', 'runtime'),
                      ('XDG_CONFIG_HOME', 'config'), ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data')]:
        directory = root / name
        directory.mkdir(mode=0o700)
        os.chown(directory, 1000, 1000)
        environment[key] = str(directory)
    prefix = ['setpriv', '--reuid=1000', '--regid=1000', '--clear-groups',
              'env', '-i', *[key + '=' + value for key, value in environment.items()]]
    assert run(prefix + ['id', '-u']).strip() == b'1000'

    def user(command, **options):
        return run(prefix + command, **options)

    def transaction(package, operation):
        run(['pacman', '-U', '--noconfirm', package])
        installed = run(['pacman', '-Q', 'poormans-text']).decode().strip()
        run(['pacman', '-Qk', 'poormans-text'])
        result['transactions'].append({'operation': operation, 'installed': installed})

    source = root / 'Quelle ü.csv'
    original = 'Name,Value\nARCHCSVMARKER,Grüße\n'.encode()
    source.write_bytes(original)
    os.chown(source, 1000, 1000)

    def csv(name):
        output = root / name
        response = json.loads(user(['/usr/bin/poormans-text', '--json', '--report', '--output', output, '--', source]))
        assert response['ok']
        markdown = Path(response['markdownFile']).read_text()
        assert 'ARCHCSVMARKER' in markdown and 'Grüße' in markdown, markdown
        assert source.read_bytes() == original
        for entry in response['outputFiles']:
            assert hashlib.sha256((output / entry['path']).read_bytes()).hexdigest() == entry['sha256']

    if previous:
        transaction(args.previous_package, 'install-previous')
        csv('previous-result')
    transaction(args.package, 'upgrade' if previous else 'install')
    csv('current-result')
    installed_binary = Path('/usr/lib/poormans-text/bin/poormans-text')
    result['installedCLISHA256'] = hashlib.sha256(installed_binary.read_bytes()).hexdigest()
    assert result['installedCLISHA256'] == '66ec0c0ded5e2d3ef06d84b476b68f2a39b1493cf5c4d8c61fedeecc89a40244'
    catalog = json.loads(user(['/usr/bin/poormans-text', '--json', '--formats']))
    images = [entry for entry in catalog['formats'] if entry['format'] == 'image']
    assert len(images) == 1 and images[0]['available'] and 'heic' in images[0]['extensions']
    assert 'png' in images[0]['extensions']
    for name in ['single', 'rotated', 'multi']:
        source_heic = args.heic_fixtures / (name + '.heic')
        original_hash = hashlib.sha256(source_heic.read_bytes()).hexdigest()
        for ocr in ['off', 'on']:
            response = json.loads(user(['/usr/bin/poormans-text', '--json', '--report', '--image-ocr', ocr,
                '--ocr-language', 'en', '--output', root / (name + '-' + ocr), '--', source_heic]))
            assert response['ok']
            assert not any(item['code'] == 'ocr.backendFailure' for item in response.get('diagnostics', []))
            assets = [Path(path) for path in response['assets']]
            original_asset = next(path for path in assets if path.suffix == '.heic')
            assert hashlib.sha256(original_asset.read_bytes()).hexdigest() == original_hash
            assert hashlib.sha256(source_heic.read_bytes()).hexdigest() == original_hash
            assert sum(path.suffix == '.png' for path in assets) == (2 if name == 'multi' else 1)
    result.update({'unprivilegedRuntimeUID': 1000, 'unicodeCSVAndReportHashes': True,
                   'installedArchHEICOffAndOn': 6, 'HEICOriginalBytesAndPNGs': True})
    gui_output = user(['/usr/bin/python3', '-I', Path(__file__).with_name('gui_probe.py'),
                       '--app', '/usr/bin/poormans-text-app', '--screenshot', args.evidence.with_suffix('.png')], timeout=60)
    result['gui'] = json.loads(next(line.split(' ', 1)[1] for line in gui_output.decode().splitlines()
                                    if line.startswith('PMT_ARCH_GUI_RESULT ')))
    user_files = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in root.rglob('*') if path.is_file() and not path.is_symlink()}
    run(['pacman', '-R', '--noconfirm', 'poormans-text'])
    run(['pacman', '-Q', 'poormans-text'], expected=1)
    for path in ['/usr/bin/poormans-text', '/usr/bin/poormans-text-app',
                 '/usr/lib/poormans-text', '/usr/share/applications/org.poormanstext.Linux.desktop']:
        assert not Path(path).exists(), path
    assert source.read_bytes() == original
    for relative, expected in user_files.items():
        assert hashlib.sha256((root / relative).read_bytes()).hexdigest() == expected
    result['transactions'].append({'operation': 'remove', 'packageFilesAbsent': True, 'userDataUnchanged': True})
    assert run(['pacman-conf', 'SigLevel', 'LocalFileSigLevel']) == policy

args.evidence.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
