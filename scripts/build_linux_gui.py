#!/usr/bin/env python3
"""Baut die dünne GTK-Oberfläche und ergänzt die bestehende lokale CLI-Laufzeit."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import subprocess
import tempfile
import tomllib
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('configuration', choices=['debug', 'release'], nargs='?', default='release')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
version = re.search(r'static let version = "([0-9.]+)"', (repo / 'Sources/PoorMansTextCore/ProductInfo.swift').read_text())[1]
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC

def directory(path):
    descriptor = os.open('/', flags)
    try:
        for component in path.absolute().parts[1:]:
            child = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise

def unchanged(path, descriptor):
    observed = directory(path)
    try:
        a, b = os.fstat(descriptor), os.fstat(observed)
        return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)
    finally:
        os.close(observed)

def rust_notices(cargo_held):
    lock = tomllib.loads((repo / 'Cargo.lock').read_text())
    roots = list((cargo_held / 'registry/src').iterdir())
    notices = bytearray(b"PMT Linux GTK preview: third-party Rust crate licenses\n\n")
    inventory = []
    for package in lock['package']:
        if not package.get('source', '').startswith('registry+'):
            continue
        name = package['name'] + '-' + package['version']
        candidates = [root / name for root in roots if (root / name).is_dir()]
        if len(candidates) != 1:
            raise SystemExit('Expected exactly one cached registry crate: ' + name)
        crate = candidates[0]
        metadata = tomllib.loads((crate / 'Cargo.toml').read_text())['package']
        if (metadata['name'], metadata['version']) != (package['name'], package['version']):
            raise SystemExit('Cached crate identity mismatch: ' + name)
        files = sorted(path for path in crate.iterdir() if path.name.upper().startswith(('LICENSE', 'COPYRIGHT', 'COPYING', 'UNLICENSE')))
        if not files or any(path.is_symlink() or not path.is_file() for path in files):
            raise SystemExit('Missing or irregular crate license files: ' + name)
        record = dict(name=package['name'], version=package['version'], checksum=package['checksum'],
                      license=metadata.get('license'), files=[])
        for path in files:
            data = path.read_bytes()
            record['files'].append(dict(name=path.name, sha256=hashlib.sha256(data).hexdigest()))
            notices.extend(('\n===== ' + name + '/' + path.name + ' =====\n').encode())
            notices.extend(data)
            notices.extend(b'\n')
        inventory.append(record)
    notices.extend(b'\n===== Locked crate inventory =====\n')
    notices.extend(json.dumps(inventory, indent=2).encode() + b'\n')
    return notices

def toolchain_notices(image):
    command = ['bash', '-eu', '-c', '\n'.join([
        'root="$(rustc --print sysroot)/share/doc/rust"',
        'test -f "$root/COPYRIGHT-library.html"',
        'for file in "$root"/COPYRIGHT*.html "$root"/licenses/*.txt; do',
        'printf "\\n===== Rust toolchain %s =====\\n" "${file##*/}"; cat "$file";',
        'done'])]
    if image:
        command = ['docker', 'run', '--rm', '--pull', 'never', '--network', 'none', image, *command]
    return subprocess.check_output(command)

root_fd = directory(repo)
sys.dont_write_bytecode = True
sys.path.insert(0, f'/proc/self/fd/{root_fd}/scripts')
from linux_build_support import publish_launcher
retained = []
build_fd = os.open('.build', flags, dir_fd=root_fd)
try:
    image = os.environ.get('PMT_LINUX_GUI_BUILD_IMAGE')
    cache = repo / '.build/linux-ui-cargo'
    try:
        os.mkdir(cache.name, 0o755, dir_fd=build_fd)
    except FileExistsError:
        pass
    cache_fd = os.open(cache.name, flags, dir_fd=build_fd)
    retained.append(cache_fd)
    cache_held = Path('/proc/self/fd') / str(cache_fd)
    if not (cache_held / 'registry').exists():
        registry = Path.home() / '.cargo/registry'
        if registry.is_dir():
            # Nur öffentliche Registrydaten, keine Cargo-Konfiguration oder Credentials.
            subprocess.run(['cp', '-a', '--reflink=auto', str(registry), str(cache_held / 'registry')],
                           pass_fds=(cache_fd,), check=True)
    cargo_home = Path(os.environ.get('PMT_CARGO_HOME', str(cache))).absolute()
    cargo_fd = directory(cargo_home)
    retained.append(cargo_fd)
    target = repo / ('.build/linux-ui-ubuntu-target' if image else '.build/linux-ui-native-target')
    try:
        os.mkdir(target.name, 0o755, dir_fd=build_fd)
    except FileExistsError:
        pass
    target_fd = os.open(target.name, flags, dir_fd=build_fd)
    retained.append(target_fd)
    target_identity = os.fstat(target_fd)
    cargo_identity = os.fstat(cargo_fd)
    def parents_unchanged():
        return (unchanged(repo, root_fd) and unchanged(repo / '.build', build_fd)
                and unchanged(cache, cache_fd) and unchanged(cargo_home, cargo_fd)
                and unchanged(target, target_fd))
    with tempfile.TemporaryDirectory(prefix='pmt-linux-gui-source-') as temporary:
        source = Path(temporary)
        for name in ['Cargo.toml', 'Cargo.lock']:
            shutil.copy2(repo / name, source / name)
        shutil.copytree(repo / 'linux', source / 'linux', symlinks=True)
        source_files = {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in sorted(source.rglob('*')) if path.is_file()}
        source_digest = hashlib.sha256(json.dumps(source_files, sort_keys=True).encode()).hexdigest()
        command = ['cargo', 'build', '--locked', '--offline', '--jobs', '4', '-p', 'poormans-text-gtk']
        if args.configuration == 'release':
            command += ['--release']
        if not parents_unchanged():
            raise SystemExit('A GUI build directory changed before compilation.')
        if image:
            if any(',' in str(path) or ':' in str(path) for path in (source, cargo_home, target)):
                raise SystemExit('Docker bind paths containing commas or colons are unsupported.')
            image = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', image], text=True).strip()
            invocation = ['docker', 'run', '--rm', '--pull', 'never', '--network', 'none',
                          '--user', f'{os.getuid()}:{os.getgid()}',
                          '-v', f'{source}:/source:ro', '-v', f'{cargo_home}:/cargo',
                          '-v', f'{target}:/target', '-e', 'CARGO_HOME=/cargo',
                          '-e', 'CARGO_TARGET_DIR=/target', '-e', 'RUSTFLAGS=-C target-cpu=x86-64',
                          '-w', '/source', image, 'bash', '-eu', '-c',
                          'test "$(stat -c %d:%i /target)" = "$1"; test "$(stat -c %d:%i /cargo)" = "$2"; shift 2; exec "$@"',
                          'build-gui', f'{target_identity.st_dev}:{target_identity.st_ino}',
                          f'{cargo_identity.st_dev}:{cargo_identity.st_ino}', *command]
            subprocess.run(invocation, check=True)
        else:
            environment = dict(os.environ, CARGO_HOME=f'/proc/self/fd/{cargo_fd}', CARGO_TARGET_DIR=f'/proc/self/fd/{target_fd}',
                               RUSTFLAGS='-C target-cpu=x86-64')
            subprocess.run(command, cwd=source, env=environment, pass_fds=(cargo_fd, target_fd), check=True)
        schema_output = source / 'compiled-schemas'
        schema_output.mkdir(mode=0o700)
        if image:
            schema_command = ['docker', 'run', '--rm', '--pull', 'never', '--network', 'none',
                '--user', f'{os.getuid()}:{os.getgid()}',
                '-v', f'{source}:/source:ro', '-v', f'{schema_output}:/compiled', image,
                'glib-compile-schemas', '--strict', '--targetdir=/compiled', '/source/linux/app/schemas']
        else:
            schema_command = ['glib-compile-schemas', '--strict', f'--targetdir={schema_output}',
                              str(source / 'linux/app/schemas')]
        subprocess.run(schema_command, check=True)
        schema_data = (schema_output / 'gschemas.compiled').read_bytes()
        if not 8 <= len(schema_data) <= 1_048_576:
            raise SystemExit('The bundled GTK preferences schema exceeds its build limits.')
    binary = Path('/proc/self/fd') / str(target_fd) / args.configuration / 'poormans-text-gtk'
    if not stat.S_ISREG(binary.lstat().st_mode):
        raise SystemExit('The GTK build did not produce a regular executable.')
    lock = os.open('linux-build.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=build_fd)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    runtime_fd = os.open('linux-runtime', flags, dir_fd=build_fd)
    try:
        runtime = repo / '.build/linux-runtime'
        held = Path('/proc/self/fd') / str(runtime_fd)
        environment = dict(os.environ, LD_LIBRARY_PATH=str(held / 'lib'))
        actual = subprocess.check_output([str(held / 'bin/poormans-text'), '--version'], env=environment,
                                         pass_fds=(runtime_fd,), text=True).strip()
        if actual != "Poor Man's Text " + version:
            raise SystemExit('Build the version-matching Linux CLI before the GTK interface.')
        name = 'ui-new-' + uuid.uuid4().hex
        os.mkdir(name, 0o700, dir_fd=runtime_fd)
        stage = held / name
        try:
            shutil.copy2(binary, stage / 'poormans-text-app')
            shutil.copy2(held / 'bin/poormans-text-process-guard', stage / 'poormans-text-process-guard')
            (stage / 'poormans-text').write_text('''#!/bin/sh
runtime=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || exit
LD_LIBRARY_PATH="$runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$runtime/bin/poormans-text" "$@"
''')
            (stage / 'THIRD-PARTY-NOTICES.txt').write_bytes(rust_notices(Path('/proc/self/fd') / str(cargo_fd)) + toolchain_notices(image))
            (stage / 'schemas').mkdir(mode=0o755)
            (stage / 'schemas/gschemas.compiled').write_bytes(schema_data)
            (stage / 'schemas/gschemas.compiled').chmod(0o644)
            for entry in stage.iterdir():
                entry.chmod(0o644 if entry.name == 'THIRD-PARTY-NOTICES.txt' else 0o755)
            (stage / 'build-info.json').write_text(json.dumps({'producer': 'pmt-linux-gui-build-v1', 'product': 'Poor Mans Text GTK', 'version': version,
                'configuration': args.configuration, 'ubuntuBuild': bool(image), 'builderImage': image,
                'sourceTreeSHA256': source_digest, 'sourceFiles': source_files,
                'cliSHA256': hashlib.sha256((held / 'bin/poormans-text').read_bytes()).hexdigest(),
                'guardSHA256': hashlib.sha256((stage / 'poormans-text-process-guard').read_bytes()).hexdigest(),
                'preferencesSchemaSHA256': hashlib.sha256(schema_data).hexdigest(),
                'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest()}, indent=2) + '\n')
            if not (parents_unchanged() and unchanged(runtime, runtime_fd)):
                raise SystemExit('A build parent changed; refusing GUI publication.')
            backup = None
            try:
                previous = os.stat('ui', dir_fd=runtime_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                if not stat.S_ISDIR(previous.st_mode):
                    raise SystemExit('The existing GUI directory is not a regular build directory.')
                old_fd = os.open('ui', flags, dir_fd=runtime_fd)
                retained.append(old_fd)
                try:
                    old = Path('/proc/self/fd') / str(old_fd)
                    expected = {'poormans-text-app', 'poormans-text', 'poormans-text-process-guard', 'build-info.json', 'THIRD-PARTY-NOTICES.txt'}
                    regular_files = expected.copy()
                    info = json.loads((old / 'build-info.json').read_text())
                    if 'preferencesSchemaSHA256' in info:
                        expected.add('schemas')
                        schema_fd = os.open('schemas', flags, dir_fd=old_fd)
                        try:
                            if set(os.listdir(schema_fd)) != {'gschemas.compiled'}:
                                raise SystemExit('The existing GUI schema directory contains unknown files.')
                            compiled_fd = os.open('gschemas.compiled', os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=schema_fd)
                            with os.fdopen(compiled_fd, 'rb') as compiled:
                                metadata = os.fstat(compiled.fileno())
                                if not stat.S_ISREG(metadata.st_mode) or not 8 <= metadata.st_size <= 1_048_576:
                                    raise SystemExit('The existing GUI preferences schema is irregular.')
                                if hashlib.sha256(compiled.read(1_048_577)).hexdigest() != info['preferencesSchemaSHA256']:
                                    raise SystemExit('The existing GUI preferences schema was modified.')
                        finally:
                            os.close(schema_fd)
                    if set(os.listdir(old_fd)) != expected or any(not stat.S_ISREG(os.stat(n, dir_fd=old_fd, follow_symlinks=False).st_mode) for n in regular_files):
                        raise SystemExit('The existing GUI directory contains unknown files.')
                    if (info.get('producer') != 'pmt-linux-gui-build-v1'
                            or info.get('product') != 'Poor Mans Text GTK'
                            or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){2}', info.get('version', ''))
                            or info.get('binarySHA256') != hashlib.sha256((old / 'poormans-text-app').read_bytes()).hexdigest()):
                        raise SystemExit('The existing GUI directory is not a recognized build artifact.')
                except BaseException:
                    raise
                backup = 'ui-old-' + uuid.uuid4().hex
                os.rename('ui', backup, src_dir_fd=runtime_fd, dst_dir_fd=runtime_fd)
                moved = os.stat(backup, dir_fd=runtime_fd, follow_symlinks=False)
                validated = os.fstat(old_fd)
                if (moved.st_dev, moved.st_ino) != (validated.st_dev, validated.st_ino):
                    raise SystemExit('GUI artifact changed during publication; unknown backup retained: ' + backup)
            try:
                os.rename(name, 'ui', src_dir_fd=runtime_fd, dst_dir_fd=runtime_fd)
            except BaseException:
                if backup:
                    os.rename(backup, 'ui', src_dir_fd=runtime_fd, dst_dir_fd=runtime_fd)
                raise
            if backup:
                print('Previous GUI retained for explicit cleanup: ' + backup)
            launcher_text = '''#!/bin/sh
# Generated by PMT Linux GUI build.
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit
exec "$base/.build/linux-runtime/ui/poormans-text-app" "$@"
'''
            publish_launcher(root_fd, 'poormans-text-app', launcher_text.encode(), 'scripts/run_linux_gui.sh')
            if not (parents_unchanged() and unchanged(runtime, runtime_fd)):
                raise SystemExit('A build parent changed; complete GUI artifact retained at the held original parent, no success reported.')
        finally:
            if (held / name).exists():
                print('GUI stage retained at the held original parent: ' + name, file=sys.stderr)
    finally:
        os.close(runtime_fd)
        os.close(lock)
finally:
    for descriptor in reversed(retained):
        os.close(descriptor)
    os.close(build_fd)
    os.close(root_fd)
print('Linux GTK interface ready: ' + str(repo / 'poormans-text-app'))
