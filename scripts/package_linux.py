#!/usr/bin/env python3
"""Erzeugt lokale Linux-CLI-Pakete; installiert und veröffentlicht nichts."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--format', choices=['deb', 'arch', 'tar', 'all'], default='all')
parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
parser.add_argument('--no-build', action='store_true')
parser.add_argument('--with-gui', action='store_true', help='Include the GTK interface built on the Ubuntu baseline.')
parser.add_argument('--output-directory', type=Path)
args = parser.parse_args()
arch_gui_dependencies = 'depend = gtk4>=4.12\ndepend = dconf' if args.with_gui else ''
repo = Path(__file__).resolve().parent.parent
if not args.no_build:
    subprocess.run([str(repo / 'build.sh'), *(['--with-gui'] if args.with_gui else []), args.configuration], check=True)
build_lock = os.open(repo / '.build/linux-build.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
fcntl.flock(build_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
runtime = repo / '.build/linux-runtime'
version = re.search(r'static let version = "([0-9.]+)"', (repo / 'Sources/PoorMansTextCore/ProductInfo.swift').read_text())[1]
environment = dict(os.environ, LD_LIBRARY_PATH=str(runtime / 'lib'))
actual = subprocess.check_output([str(runtime / 'bin/poormans-text'), '--version'], env=environment, text=True).strip()
if actual != 'Poor Man\'s Text ' + version:
    raise SystemExit('Runtime version differs from source; rebuild before packaging.')
if args.with_gui:
    gui = runtime / 'ui/poormans-text-app'
    if not gui.is_file():
        raise SystemExit('Build the Linux GTK interface before packaging with --with-gui.')
    info = json.loads((runtime / 'ui/build-info.json').read_text())
    if info.get('producer') != 'pmt-linux-gui-build-v1' or info.get('version') != version:
        raise SystemExit('GUI/runtime version or producer mismatch; rebuild before packaging.')
    for key, path in [('binarySHA256', gui), ('cliSHA256', runtime / 'bin/poormans-text'),
                      ('guardSHA256', runtime / 'ui/poormans-text-process-guard')]:
        if info.get(key) != hashlib.sha256(path.read_bytes()).hexdigest():
            raise SystemExit('GUI/runtime fingerprint mismatch; rebuild before packaging: ' + key)
    schema = runtime / 'ui/schemas/gschemas.compiled'
    if not schema.is_file() or schema.is_symlink() or hashlib.sha256(schema.read_bytes()).hexdigest() != info.get('preferencesSchemaSHA256'):
        raise SystemExit('The bundled GUI preferences schema is missing or modified; rebuild before packaging.')
# Die separat geprüfte Modellruntime wird ausschließlich lokal über ihren
# eigenen Installer ergänzt; Basispakete übernehmen sie nie beiläufig.
excluded_runtime_roots = {'structured-ocr'} | (set() if args.with_gui else {'ui'})
excluded_runtime_roots.update(entry.name for entry in runtime.iterdir()
                              if re.fullmatch(r'ui-old-[0-9a-f]{32}', entry.name))
def runtime_entries():
    def failed(error):
        raise error
    for directory, directories, files in os.walk(runtime, followlinks=False, onerror=failed):
        if Path(directory) == runtime:
            directories[:] = [name for name in directories if name not in excluded_runtime_roots]
            files = [name for name in files if name not in excluded_runtime_roots]
        for name in directories + files:
            yield Path(directory) / name

for entry in runtime_entries():
    if entry.is_symlink():
        raise SystemExit('Unexpected runtime symlink: ' + str(entry.relative_to(runtime)))
    if not entry.is_file():
        continue
    with entry.open('rb') as stream:
        header = stream.read(20)
        elf = header[:4] == b'\x7fELF'
    if elf:
        if len(header) < 20 or header[4:6] != b'\x02\x01' or header[18:20] != b'\x3e\x00':
            raise SystemExit('Runtime ELF is not Linux x86_64: ' + str(entry.relative_to(runtime)))
        versions = re.findall(r'GLIBC_([0-9.]+)', subprocess.check_output(['readelf', '--version-info', str(entry)], text=True))
        if versions and max(tuple(map(int, item.split('.'))) for item in versions) > (2, 39):
            raise SystemExit('Runtime ELF exceeds glibc 2.39 baseline: ' + str(entry.relative_to(runtime)) + '; rebuild on Ubuntu 24.04.')
output = (args.output_directory or repo / '.build/linux-packages').absolute()
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
parent = os.open('/', flags)
try:
    for component in output.parts[1:]:
        if component in ('.', '..'):
            raise SystemExit('Package output must have a normalized path.')
        try:
            child = os.open(component, flags, dir_fd=parent)
        except FileNotFoundError:
            os.mkdir(component, 0o755, dir_fd=parent)
            child = os.open(component, flags, dir_fd=parent)
        os.close(parent)
        parent = child
except BaseException:
    os.close(parent)
    raise
formats = ['deb', 'arch', 'tar'] if args.format == 'all' else [args.format]
epoch = int(os.environ.get('SOURCE_DATE_EPOCH', subprocess.check_output(
    ['git', '-C', str(repo), 'show', '-s', '--format=%ct', 'HEAD'], text=True).strip()))
names = {'deb': f'poormans-text_{version}~linuxpreview1_amd64.deb',
         'arch': f'poormans-text-{version}-1-x86_64.pkg.tar.zst',
         'tar': f'poormans-text-{version}-linux-x86_64.tar.zst'}


def require_unchanged_parent():
    current = os.open('/', flags)
    try:
        for component in output.parts[1:]:
            child = os.open(component, flags, dir_fd=current)
            os.close(current)
            current = child
        held, observed = os.fstat(parent), os.fstat(current)
        if (held.st_dev, held.st_ino) != (observed.st_dev, observed.st_ino):
            raise SystemExit('Package output parent changed; complete files retained in the held original directory.')
    finally:
        os.close(current)


def publish(source, name):
    # Der private Bauordner liegt im gehaltenen Ziel; Hardlink publiziert atomar
    # ohne Overwrite und ohne Rename-Fallback zwischen Dateisystemen.
    require_unchanged_parent()
    try:
        os.link(source, name, dst_dir_fd=parent, follow_symlinks=False)
    except FileExistsError:
        print('Package output already exists: ' + name, file=sys.stderr)
        raise SystemExit(73)
    require_unchanged_parent()
    print(output / name, flush=True)


try:
    for kind in formats:
        for name in [names[kind], names[kind] + '.sha256']:
            try:
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                continue
            print('Package output already exists: ' + name, file=sys.stderr)
            raise SystemExit(73)
    with tempfile.TemporaryDirectory(prefix='.pmt-package-', dir=f'/proc/self/fd/{parent}') as work:
        work = Path(work)
        for kind in formats:
            stage = work / kind
            destination = stage / 'usr/lib/poormans-text'
            for path in runtime_entries():
                if path.is_symlink() or not (path.is_dir() or path.is_file()):
                    raise SystemExit('Unexpected runtime file type: ' + str(path.relative_to(runtime)))
            shutil.copytree(runtime, destination, ignore=lambda path, names: sorted(set(names) & excluded_runtime_roots) if Path(path) == runtime else [])
            for path in [destination, *destination.rglob('*')]:
                path.chmod(0o755 if path.is_dir() or path.parent in [destination / 'bin', destination / 'ui'] and path.name in ['poormans-text', 'poormans-text-app', 'poormans-text-process-guard'] else 0o644)
            launch = stage / 'usr/bin/poormans-text'
            launch.parent.mkdir(parents=True)
            launch.write_text('''#!/bin/sh
entry=$(readlink -f -- "$0") || exit
prefix=$(CDPATH= cd -- "$(dirname -- "$entry")/.." && pwd -P) || exit
runtime="$prefix/lib/poormans-text"
LD_LIBRARY_PATH="$runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$runtime/bin/poormans-text" "$@"
''')
            launch.chmod(0o755)
            if args.with_gui:
                app = stage / 'usr/bin/poormans-text-app'
                app.write_text('''#!/bin/sh
entry=$(readlink -f -- "$0") || exit
prefix=$(CDPATH= cd -- "$(dirname -- "$entry")/.." && pwd -P) || exit
exec "$prefix/lib/poormans-text/ui/poormans-text-app" "$@"
''')
                app.chmod(0o755)
                desktop = stage / 'usr/share/applications'
                desktop.mkdir(parents=True)
                (desktop / 'org.poormanstext.Linux.desktop').write_text('''[Desktop Entry]
Type=Application
Name=Poor Man's Text
GenericName=Document converter
GenericName[de]=Dokumentkonverter
Comment=Convert local documents to Markdown
Comment[de]=Lokale Dokumente in Markdown umwandeln
Exec=poormans-text-app %F
Icon=text-x-generic
Terminal=false
Categories=Office;Utility;
StartupNotify=true
''')
                (desktop / 'org.poormanstext.Linux.desktop').chmod(0o644)
            docs = stage / 'usr/share/doc/poormans-text'
            docs.mkdir(parents=True)
            for filename in ['LICENSE', 'CHANGELOG.md', 'docs/LINUX-BUILD.md']:
                shutil.copy2(repo / filename, docs / Path(filename).name)
            for directory in [stage, *(path for path in stage.rglob('*') if path.is_dir())]:
                directory.chmod(0o755)
            package = work / names[kind]
            if kind == 'deb':
                control = stage / 'DEBIAN'
                control.mkdir()
                control.chmod(0o755)
                (control / 'control').write_text(f'''Package: poormans-text
Version: {version}~linuxpreview1
Architecture: amd64
Maintainer: Poor Man's Text contributors
Section: text
Priority: optional
Depends: libc6 (>= 2.39), libstdc++6, libgcc-s1, bubblewrap (>= 0.9.0){', libgtk-4-1 (>= 4.12), dconf-gsettings-backend' if args.with_gui else ''}
Recommends: pandoc
Suggests: python3-pil, python3-gi, python3-cairo, python3-gi-cairo, gir1.2-poppler-0.18, tesseract-ocr, libreoffice-writer, python3-uno, libheif1, libheif-plugin-libde265
Homepage: https://github.com/DanielMuellerIR/poormans_text
Description: Local document conversion with a shared Swift core (Linux preview)
 No runtime downloads. Optional converters and OCR data are host packages.
''')
                (control / 'control').chmod(0o644)
                subprocess.run(['dpkg-deb', '--root-owner-group', '--threads-max=2', '-Zzstd', '-z5',
                                '--build', str(stage), str(package)], check=True, pass_fds=(parent,))
            else:
                if kind == 'arch':
                    (stage / '.PKGINFO').write_text(f'''pkgname = poormans-text
pkgbase = poormans-text
pkgver = {version}-1
pkgdesc = Local document conversion with a shared Swift core (Linux preview)
url = https://github.com/DanielMuellerIR/poormans_text
builddate = {epoch}
packager = Poor Man's Text contributors
size = {sum(p.stat().st_size for p in stage.rglob('*') if p.is_file())}
arch = x86_64
license = WTFPL
license = custom:bundled-runtime
depend = glibc>=2.39
depend = gcc-libs
depend = bubblewrap>=0.9.0
{arch_gui_dependencies}
optdepend = pandoc: document conversion
optdepend = python-pillow: raster decoding
optdepend = python-gobject: Poppler backend
optdepend = python-cairo: PDF rasterization
optdepend = poppler-glib: PDF backend
optdepend = tesseract: local OCR
optdepend = libreoffice-fresh: legacy Word import
optdepend = libheif: optional HEIC decoder
optdepend = ffmpeg: optional runtime for distro libheif plugins
''')
                if kind == 'arch':
                    (stage / '.PKGINFO').chmod(0o644)
                subprocess.run(['tar', '--zstd', '--sort=name', f'--mtime=@{epoch}', '--owner=0', '--group=0',
                                '--numeric-owner', '-cf', str(package), '-C', str(stage),
                                *sorted(path.name for path in stage.iterdir())], check=True, pass_fds=(parent,))
            package.chmod(0o644)
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            checksum = work / (names[kind] + '.sha256')
            checksum.write_text(digest + '  ' + names[kind] + '\n')
            checksum.chmod(0o644)
            publish(package, names[kind])
            publish(checksum, names[kind] + '.sha256')
finally:
    os.close(parent)
    os.close(build_lock)
