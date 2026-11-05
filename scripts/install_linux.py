#!/usr/bin/env python3
"""Baut oder verwendet ein natives Linux-Paket und installiert es über apt/pacman."""
import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

from linux_release_signing import fingerprint, open_file, stamp, verify_file, copy_regular


def manager_for(package, choice):
    if choice != 'auto':
        return choice
    if package:
        if package.name.endswith('.deb'):
            return 'apt'
        if package.name.endswith('.pkg.tar.zst'):
            return 'pacman'
        raise ValueError('Installation requires a .deb or .pkg.tar.zst package; unpack portable archives instead.')
    distro = Path('/etc/os-release').read_text().lower()
    return 'pacman' if any(name in distro for name in ('arch', 'cachyos', 'manjaro')) else 'apt'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, help='Existing local native package; otherwise build a new one.')
    parser.add_argument('--package-manager', choices=['auto', 'apt', 'pacman'], default='auto')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--cli-only', action='store_true')
    parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
    parser.add_argument('--sign-key', type=fingerprint, help='Key for a newly built package.')
    parser.add_argument('--keyring', type=Path, help='Trusted exported public keyring; verify before installing.')
    parser.add_argument('--fingerprint', type=fingerprint)
    parser.add_argument('--signature', type=Path)
    parser.add_argument('--dry-run', action='store_true', help='Print build/install commands without executing them.')
    args = parser.parse_args()
    if not sys.platform.startswith('linux'):
        parser.error('Run this installer on Linux.')
    if bool(args.keyring) != bool(args.fingerprint) or (args.signature and not args.keyring):
        parser.error('Signature verification requires --keyring and --fingerprint together.')
    if args.package and args.sign_key:
        parser.error('Use sign-linux.sh to sign an existing package.')
    manager = manager_for(args.package, args.package_manager)
    executable = shutil.which('apt-get' if manager == 'apt' else 'pacman')
    if not executable:
        raise ValueError('The selected native package manager is not installed.')
    privilege = [] if os.geteuid() == 0 else ['sudo', '--']
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='pmt-linux-install-') as temporary:
        work = Path(temporary)
        package = args.package.absolute() if args.package else None
        if package is None:
            version = re.search(r'static let version = "([0-9.]+)"', (repo/'Sources/PoorMansTextCore/ProductInfo.swift').read_text())[1]
            name = f'poormans-text_{version}~linuxpreview1_amd64.deb' if manager == 'apt' else f'poormans-text-{version}-1-x86_64.pkg.tar.zst'
            package = work/name
            command = [str(repo/'release-linux.sh'), '--format', 'deb' if manager == 'apt' else 'arch',
                       '--output-directory', str(work), '--configuration', args.configuration]
            if args.no_build:
                command.append('--no-build')
            if args.cli_only:
                command.append('--cli-only')
            if args.sign_key:
                command += ['--sign-key', args.sign_key]
            if args.dry_run:
                print(shlex.join(command))
            else:
                subprocess.run(command, check=True)
        expected_suffix = '.deb' if manager == 'apt' else '.pkg.tar.zst'
        if not package.name.endswith(expected_suffix):
            raise ValueError('Package type does not match the selected package manager.')
        staged = work/('install'+expected_suffix)
        if not args.dry_run:
            descriptor = open_file(package)
            try:
                before = os.fstat(descriptor)
                copy_regular(descriptor, staged)
                if stamp(before) != stamp(os.fstat(descriptor)):
                    raise ValueError('Package changed while staging.')
            finally:
                os.close(descriptor)
            if manager == 'apt':
                identity = subprocess.check_output(['dpkg-deb', '-f', str(staged), 'Package'], text=True).strip()
                if identity != 'poormans-text':
                    raise ValueError("This is not a Poor Man's Text package.")
            else:
                metadata = subprocess.check_output(['tar', '--zstd', '-xOf', str(staged), '.PKGINFO'], text=True)
                if re.findall(r'^pkgname = (.+)$', metadata, re.MULTILINE) != ['poormans-text']:
                    raise ValueError("This is not a Poor Man's Text package.")
            signature = args.signature or package.with_name(package.name+'.sig')
            if args.keyring or signature.exists() or signature.is_symlink():
                sig_fd = open_file(signature)
                try:
                    if os.fstat(sig_fd).st_size > 1024**2:
                        raise ValueError('Signature exceeds 1 MiB.')
                    staged_signature = staged.with_name(staged.name+'.sig')
                    copy_regular(sig_fd, staged_signature)
                    staged_signature.chmod(0o644)
                finally:
                    os.close(sig_fd)
                if args.keyring:
                    verify_file(staged, staged_signature, args.keyring, args.fingerprint)
            # apt/_apt muss das private Installationspaket lesen können.
            work.chmod(0o755)
            staged.chmod(0o644)
        command = privilege + [executable, 'install' if manager == 'apt' else '-U', '--', str(staged)]
        if args.dry_run:
            print(shlex.join(command))
        else:
            subprocess.run(command, check=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
