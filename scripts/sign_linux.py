#!/usr/bin/env python3
"""Signiert oder prüft ein vorhandenes Linux-Artefakt; installiert nichts."""
import argparse
import os
from pathlib import Path
import sys
import subprocess
import tempfile

from linux_release_signing import directory, fingerprint, unchanged_parent, verify_file, sign_file, open_file, stamp, copy_regular


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    signing = commands.add_parser('sign')
    signing.add_argument('artifact', type=Path)
    signing.add_argument('--key', required=True, type=fingerprint)
    verifying = commands.add_parser('verify')
    verifying.add_argument('artifact', type=Path)
    verifying.add_argument('--signature', type=Path)
    verifying.add_argument('--keyring', required=True, type=Path)
    verifying.add_argument('--fingerprint', required=True, type=fingerprint)
    args = parser.parse_args()
    path = args.artifact.absolute()
    if args.command == 'verify':
        verify_file(path, args.signature or path.with_name(path.name + '.sig'), args.keyring, args.fingerprint)
        print('SIGNATURE OK: ' + str(path))
        return
    parent = directory(path.parent)
    try:
        target = path.name + '.sig'
        try:
            os.stat(target, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise FileExistsError('Signature already exists; preserved.')
        descriptor = open_file(path)
        try:
            before = os.fstat(descriptor)
            with tempfile.TemporaryDirectory(prefix='.pmt-sign-', dir=f'/proc/self/fd/{parent}') as work:
                staged = Path(work) / path.name
                copy_regular(descriptor, staged)
                if stamp(before) != stamp(os.fstat(descriptor)):
                    raise ValueError('Artifact changed while copying.')
                signature = sign_file(staged, args.key)
                unchanged_parent(path.parent, parent)
                if stamp(before) != stamp(os.stat(path.name, dir_fd=parent, follow_symlinks=False)):
                    raise ValueError('Artifact entry changed; no signature published.')
                os.link(signature, target, dst_dir_fd=parent, follow_symlinks=False)
                unchanged_parent(path.parent, parent)
        finally:
            os.close(descriptor)
        print(path.with_name(target))
    finally:
        os.close(parent)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(73 if isinstance(error, FileExistsError) else 1)
