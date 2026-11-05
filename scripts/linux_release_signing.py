"""Explizite OpenPGP-Signaturen über gebundene lokale Paketdateien."""
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile

DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def fingerprint(value):
    value = value.upper()
    if not re.fullmatch(r'(?:[0-9A-F]{40}|[0-9A-F]{64})', value):
        raise ValueError('Use a complete signing-key fingerprint (40 or 64 hex characters).')
    return value


def directory(path):
    if '..' in Path(path).parts:
        raise ValueError('Paths must not contain parent aliases.')
    path = Path(os.path.abspath(path))
    descriptor = os.open('/', DIRECTORY_FLAGS)
    try:
        for part in path.parts[1:]:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def unchanged_parent(path, descriptor):
    current = directory(path)
    try:
        a, b = os.fstat(current), os.fstat(descriptor)
        if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
            raise ValueError('Artifact parent changed; no success reported.')
    finally:
        os.close(current)


def stamp(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)


def open_file(path):
    parent = directory(path.parent)
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                             dir_fd=parent)
    finally:
        os.close(parent)
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise ValueError('Only regular files are accepted.')
    return descriptor


def copy_regular(descriptor, target):
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or not 0 <= before.st_size <= 4 * 1024**3:
        raise ValueError('Package must be a regular file of at most 4 GiB.')
    remaining = before.st_size
    with target.open('xb') as output:
        while remaining:
            block = os.read(descriptor, min(1024**2, remaining))
            if not block:
                raise ValueError('Package truncated while copying.')
            output.write(block)
            remaining -= len(block)
    if os.read(descriptor, 1) or stamp(before) != stamp(os.fstat(descriptor)):
        raise ValueError('Package changed while copying.')
    return before


def check_signature(artifact_fd, signature_fd, keyring, expected):
    expected = fingerprint(expected)
    key_fd = open_file(Path(keyring).absolute())
    try:
        # gpgv benutzt ausschließlich den ausdrücklich bereitgestellten Vertrauensanker.
        with tempfile.TemporaryDirectory(prefix='pmt-gpgv-') as home:
            result = subprocess.run([
                'gpgv', '--homedir', home, '--keyring', f'/proc/self/fd/{key_fd}',
                '--status-fd', '1', f'/proc/self/fd/{signature_fd}', f'/proc/self/fd/{artifact_fd}',
            ], pass_fds=(artifact_fd, signature_fd, key_fd), capture_output=True, text=True, timeout=60)
        valid = [line.split()[2:] for line in result.stdout.splitlines()
                 if line.startswith('[GNUPG:] VALIDSIG ')]
        if result.returncode != 0 or len(valid) != 1 or expected not in (valid[0][0], valid[0][-1]):
            raise ValueError('Signature verification failed or signer fingerprint differs.')
    finally:
        os.close(key_fd)


def sign_file(path, key):
    """Erzeugt eine private Signatur; der Aufrufer publiziert sie ohne Overwrite."""
    key = fingerprint(key)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('Only regular staged files are accepted.')
        signature = path.with_name(path.name + '.sig')
        result = subprocess.run([
            'gpg', '--batch', '--local-user', key, '--output', '-',
            '--detach-sign', f'/proc/self/fd/{descriptor}',
        ], pass_fds=(descriptor,), capture_output=True, timeout=120)
        if result.returncode != 0:
            raise ValueError('GPG signing failed; check the selected key and signing agent.')
        if stamp(before) != stamp(os.fstat(descriptor)):
            raise ValueError('Artifact changed while signing.')
        if len(result.stdout) > 1024 * 1024:
            raise ValueError('Unexpectedly large signature.')
        with signature.open('xb') as stream:
            stream.write(result.stdout)
        signature.chmod(0o644)
        return signature
    finally:
        os.close(descriptor)


def verify_file(path, signature, keyring, expected):
    descriptor = open_file(path)
    try:
        signature_fd = open_file(signature)
    except BaseException:
        os.close(descriptor)
        raise
    try:
        before = os.fstat(descriptor)
        signature_before = os.fstat(signature_fd)
        check_signature(descriptor, signature_fd, keyring, expected)
        if stamp(before) != stamp(os.fstat(descriptor)) or stamp(signature_before) != stamp(os.fstat(signature_fd)):
            raise ValueError('Artifact or signature changed while verifying.')
    finally:
        os.close(signature_fd)
        os.close(descriptor)
