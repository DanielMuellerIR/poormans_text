#!/usr/bin/env python3
"""Installiert ausschließlich eine bereits entpackte, extern geprüfte lokale OCR-Runtime."""
import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import stat
import sys
import uuid

DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
MANIFEST_NAME = 'runtime-manifest.json'
TARGET_NAME = 'structured-ocr'
MAX_MANIFEST_BYTES = 8 * 1024**2
MAX_FILES = 32768
MAX_TOTAL_BYTES = 4 * 1024**3
MAX_PATH_BYTES = 4096
MAX_RELATIVE_DEPTH = 64
MAX_DERIVED_DIRECTORIES = 65536


class InstallError(Exception):
    pass


def require_utf8_path_budget(value):
    try:
        length = len(value.encode('utf-8', errors='strict'))
    except UnicodeEncodeError as error:
        raise InstallError('Paths must contain valid UTF-8.') from error
    if length > MAX_PATH_BYTES:
        raise InstallError('Path exceeds 4096 UTF-8 bytes.')


def normalized_absolute(value):
    if not isinstance(value, str) or not value.startswith('/') or value == '/':
        raise InstallError('An absolute, normalized directory path is required.')
    require_utf8_path_budget(value)
    parts = value.split('/')[1:]
    if any(not component or component in ('.', '..') or '\x00' in component for component in parts):
        raise InstallError('Directory paths must not contain aliases or empty components.')
    return parts


def open_directory(value, forbidden_identity=None):
    parts = normalized_absolute(value)
    descriptor = os.open('/', DIRECTORY_FLAGS)
    try:
        for component in parts:
            child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            if forbidden_identity is not None and identity(child) == forbidden_identity:
                os.close(child)
                raise InstallError('Runtime parent must not be inside the source inode tree.')
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def identity(descriptor):
    value = os.fstat(descriptor)
    return value.st_dev, value.st_ino


def stamp(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def require_directory_identity(path, descriptor):
    observed = open_directory(path)
    try:
        if identity(observed) != identity(descriptor):
            raise InstallError('Directory changed: ' + path)
    finally:
        os.close(observed)


def regular_file(descriptor):
    value = os.fstat(descriptor)
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
        raise InstallError('Only regular files with one link are accepted.')
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InstallError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def relative_components(value):
    if not isinstance(value, str) or not value or value.startswith('/') or '\\' in value:
        raise InstallError('Manifest paths must be unambiguous relative POSIX paths.')
    require_utf8_path_budget(value)
    parts = value.split('/')
    if len(parts) > MAX_RELATIVE_DEPTH:
        raise InstallError('Manifest path exceeds 64 components.')
    if any(not part or part in ('.', '..') or any(ord(c) < 32 or ord(c) == 127 for c in part) for part in parts):
        raise InstallError('Invalid manifest path.')
    if any(len(part.encode('utf-8')) > 255 for part in parts):
        raise InstallError('Manifest path component exceeds the filesystem limit.')
    return parts


def read_manifest(source, expected):
    if not re.fullmatch('[0-9a-f]{64}', expected):
        raise InstallError('Expected manifest SHA256 must contain 64 lowercase hexadecimal characters.')
    descriptor = os.open(MANIFEST_NAME, FILE_FLAGS, dir_fd=source)
    try:
        before = regular_file(descriptor)
        if before.st_size > MAX_MANIFEST_BYTES:
            raise InstallError('Manifest exceeds 8 MiB.')
        payload = bytearray()
        while len(payload) <= MAX_MANIFEST_BYTES:
            block = os.read(descriptor, min(1024**2, MAX_MANIFEST_BYTES + 1 - len(payload)))
            if not block:
                break
            payload.extend(block)
        if len(payload) != before.st_size or stamp(before) != stamp(os.fstat(descriptor)):
            raise InstallError('Manifest changed while reading.')
        if hashlib.sha256(payload).hexdigest() != expected:
            raise InstallError('Manifest SHA256 differs from the caller-reviewed digest.')
        observed = os.stat(MANIFEST_NAME, dir_fd=source, follow_symlinks=False)
        if stamp(observed) != stamp(before):
            raise InstallError('Manifest entry changed.')
    finally:
        os.close(descriptor)
    def invalid_constant(value):
        raise InstallError('Non-finite JSON value: ' + value)
    try:
        document = json.loads(payload.decode('utf-8'), object_pairs_hook=unique_object,
                              parse_constant=invalid_constant)
    except RecursionError as error:
        raise InstallError('Runtime manifest JSON exceeds the parser nesting limit.') from error
    if not isinstance(document, dict) or type(document.get('schemaVersion')) is not int or document['schemaVersion'] != 1:
        raise InstallError('Unsupported runtime manifest schema.')
    if document.get('backend') != 'docling' or type(document.get('qualifiedAdapterVersion')) is not int or document['qualifiedAdapterVersion'] != 1:
        raise InstallError('Unsupported runtime backend or adapter version.')
    files = document.get('files')
    if not isinstance(files, dict) or not 1 <= len(files) <= MAX_FILES:
        raise InstallError('Manifest must contain 1 through 32768 files.')
    directories = {''}
    total = 0
    for name, record in files.items():
        parts = relative_components(name)
        if name == MANIFEST_NAME or not isinstance(record, dict) or set(record) != {'sha256', 'byteCount'}:
            raise InstallError('Invalid manifest file record.')
        if not isinstance(record['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', record['sha256']):
            raise InstallError('Invalid file SHA256.')
        if type(record['byteCount']) is not int or not 0 <= record['byteCount'] <= MAX_TOTAL_BYTES:
            raise InstallError('Invalid file byte count.')
        total += record['byteCount']
        if total > MAX_TOTAL_BYTES:
            raise InstallError('Runtime exceeds 4 GiB.')
        for depth in range(1, len(parts)):
            directories.add('/'.join(parts[:depth]))
            # Der leere Wurzelmarker ist kein abgeleitetes Unterverzeichnis.
            if len(directories) - 1 > MAX_DERIVED_DIRECTORIES:
                raise InstallError('Runtime exceeds 65536 derived directories.')
    if directories.intersection(files) or 'bin/python3.12' not in files:
        raise InstallError('Conflicting paths or missing bin/python3.12.')
    return bytes(payload), files, directories, stamp(before)


def copy_file(source_parent, stage_parent, name, record, relative):
    source = os.open(name, FILE_FLAGS, dir_fd=source_parent)
    target = None
    try:
        before = regular_file(source)
        if before.st_size != record['byteCount']:
            raise InstallError('Source size differs from manifest: ' + relative)
        if relative == 'bin/python3.12' and not before.st_mode & 0o111:
            raise InstallError('bin/python3.12 must be executable.')
        target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=stage_parent)
        digest = hashlib.sha256()
        remaining = record['byteCount']
        while remaining:
            block = os.read(source, min(1024**2, remaining))
            if not block:
                raise InstallError('Source truncated while reading: ' + relative)
            digest.update(block)
            pending = memoryview(block)
            while pending:
                written = os.write(target, pending)
                if written == 0:
                    raise InstallError('Copy made no progress.')
                pending = pending[written:]
            remaining -= len(block)
        if os.read(source, 1) or digest.hexdigest() != record['sha256']:
            raise InstallError('Source content differs from manifest: ' + relative)
        if stamp(before) != stamp(os.fstat(source)) or stamp(before) != stamp(os.stat(name, dir_fd=source_parent, follow_symlinks=False)):
            raise InstallError('Source file changed: ' + relative)
        os.fchmod(target, 0o555 if before.st_mode & 0o111 else 0o444)
        os.fsync(target)
        return stamp(before)
    finally:
        if target is not None:
            os.close(target)
        os.close(source)


def directory_names(descriptor):
    # Ein vor Dateianlage geöffnetes btrfs-Verzeichnis kann trotz Offset 0 beim
    # ersten Listing leer erscheinen. openat statt dup erzeugt einen unabhängigen
    # Enumerationszustand am bereits gebundenen Verzeichnis, ohne dessen Offset zu ändern.
    current = os.open('.', DIRECTORY_FLAGS, dir_fd=descriptor)
    try:
        if identity(current) != identity(descriptor):
            raise InstallError('Bound directory changed before enumeration.')
        return os.listdir(current)
    finally:
        os.close(current)


def copy_tree(source, stage, prefix, files, directories, snapshots):
    before = os.fstat(source)
    for name in sorted(directory_names(source)):
        relative = prefix + '/' + name if prefix else name
        value = os.stat(name, dir_fd=source, follow_symlinks=False)
        if not prefix and name == MANIFEST_NAME:
            if stamp(value) != snapshots[MANIFEST_NAME]:
                raise InstallError('Manifest changed during copy.')
            continue
        if stat.S_ISDIR(value.st_mode) and relative in directories:
            child = os.open(name, DIRECTORY_FLAGS, dir_fd=source)
            target = None
            try:
                if stamp(value) != stamp(os.fstat(child)):
                    raise InstallError('Source directory entry changed.')
                os.mkdir(name, 0o700, dir_fd=stage)
                target = os.open(name, DIRECTORY_FLAGS, dir_fd=stage)
                copy_tree(child, target, relative, files, directories, snapshots)
                os.fchmod(target, 0o555)
                os.fsync(target)
            finally:
                if target is not None:
                    os.close(target)
                os.close(child)
        elif relative in files and stat.S_ISREG(value.st_mode):
            snapshots[relative] = copy_file(source, stage, name, files[relative], relative)
        else:
            raise InstallError('Unknown file, directory or special entry: ' + relative)
    if stamp(before) != stamp(os.fstat(source)):
        raise InstallError('Source directory changed during copy.')


def verify_source_tree(source, prefix, files, directories, snapshots, seen):
    before = os.fstat(source)
    for name in directory_names(source):
        relative = prefix + '/' + name if prefix else name
        value = os.stat(name, dir_fd=source, follow_symlinks=False)
        if stat.S_ISDIR(value.st_mode) and relative in directories:
            child = os.open(name, DIRECTORY_FLAGS, dir_fd=source)
            try:
                if stamp(value) != stamp(os.fstat(child)):
                    raise InstallError('Source directory changed during verification.')
                verify_source_tree(child, relative, files, directories, snapshots, seen)
            finally:
                os.close(child)
        elif relative not in snapshots or stamp(value) != snapshots[relative]:
            raise InstallError('Source entries changed before publication: ' + relative)
        else:
            seen.add(relative)
    if stamp(before) != stamp(os.fstat(source)):
        raise InstallError('Source directory changed during verification.')


def verify_stage_tree(stage, prefix, files, directories, seen):
    before = os.fstat(stage)
    for name in directory_names(stage):
        relative = prefix + '/' + name if prefix else name
        value = os.stat(name, dir_fd=stage, follow_symlinks=False)
        if stat.S_ISDIR(value.st_mode) and relative in directories:
            child = os.open(name, DIRECTORY_FLAGS, dir_fd=stage)
            try:
                if stamp(value) != stamp(os.fstat(child)) or stat.S_IMODE(value.st_mode) != 0o555:
                    raise InstallError('Stage directory changed.')
                verify_stage_tree(child, relative, files, directories, seen)
            finally:
                os.close(child)
        elif relative in files and stat.S_ISREG(value.st_mode):
            descriptor = os.open(name, FILE_FLAGS, dir_fd=stage)
            try:
                held = regular_file(descriptor)
                record = files[relative]
                if stamp(held) != stamp(value) or held.st_size != record['byteCount'] or stat.S_IMODE(held.st_mode) not in (0o444, 0o555):
                    raise InstallError('Stage file changed.')
                if relative == 'bin/python3.12' and stat.S_IMODE(held.st_mode) != 0o555:
                    raise InstallError('Staged interpreter is not executable.')
                digest = hashlib.sha256()
                remaining = record['byteCount']
                while remaining:
                    block = os.read(descriptor, min(1024**2, remaining))
                    if not block:
                        raise InstallError('Stage file truncated.')
                    digest.update(block)
                    remaining -= len(block)
                if (os.read(descriptor, 1) or digest.hexdigest() != record['sha256']
                        or stamp(held) != stamp(os.fstat(descriptor))
                        or stamp(held) != stamp(os.stat(name, dir_fd=stage, follow_symlinks=False))):
                    raise InstallError('Stage file verification failed.')
                seen.add(relative)
            finally:
                os.close(descriptor)
        else:
            raise InstallError('Unexpected stage entry: ' + relative)
    if stamp(before) != stamp(os.fstat(stage)):
        raise InstallError('Stage directory changed during verification.')


def rename_no_replace(parent, source, target):
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(parent, os.fsencode(source), parent, os.fsencode(target), 1) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def install(source_path, runtime_path, expected):
    source_parts = normalized_absolute(source_path)
    runtime_parts = normalized_absolute(runtime_path)
    if runtime_parts[:len(source_parts)] == source_parts:
        raise InstallError('Runtime parent must not be inside the source directory.')
    source = open_directory(source_path)
    parent = None
    stage = None
    stage_name = None
    published = False
    try:
        parent = open_directory(runtime_path, identity(source))
        if identity(source) == identity(parent):
            raise InstallError('Source and runtime parent must differ.')
        payload, files, directories, manifest_stamp = read_manifest(source, expected)
        try:
            os.stat(TARGET_NAME, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise InstallError('Target already exists; it was preserved.')
        require_directory_identity(runtime_path, parent)
        candidate_name = '.pmt-structured-ocr-' + uuid.uuid4().hex
        os.mkdir(candidate_name, 0o700, dir_fd=parent)
        stage_name = candidate_name
        stage = os.open(stage_name, DIRECTORY_FLAGS, dir_fd=parent)
        stage_identity = identity(stage)
        snapshots = {MANIFEST_NAME: manifest_stamp}
        copy_tree(source, stage, '', files, directories, snapshots)
        if set(snapshots) != set(files) | {MANIFEST_NAME}:
            raise InstallError('Source is missing files declared by the manifest.')
        descriptor = os.open(MANIFEST_NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                             0o600, dir_fd=stage)
        try:
            pending = memoryview(payload)
            while pending:
                written = os.write(descriptor, pending)
                if written == 0:
                    raise InstallError('Manifest copy made no progress.')
                pending = pending[written:]
            os.fchmod(descriptor, 0o444)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        source_seen = set()
        verify_source_tree(source, '', files, directories, snapshots, source_seen)
        if source_seen != set(snapshots):
            raise InstallError('Source files disappeared before publication.')
        stage_files = dict(files)
        stage_files[MANIFEST_NAME] = {'sha256': expected, 'byteCount': len(payload)}
        stage_seen = set()
        verify_stage_tree(stage, '', stage_files, directories, stage_seen)
        if stage_seen != set(stage_files):
            raise InstallError('Stage inventory differs: expected ' + str(len(stage_files))
                               + ', verified ' + str(len(stage_seen)) + ', missing '
                               + repr(sorted(set(stage_files) - stage_seen)[:3])
                               + ', unexpected ' + repr(sorted(stage_seen - set(stage_files))[:3]))
        require_directory_identity(source_path, source)
        require_directory_identity(runtime_path, parent)
        stage_entry = os.stat(stage_name, dir_fd=parent, follow_symlinks=False)
        if identity(stage) != stage_identity or (stage_entry.st_dev, stage_entry.st_ino) != stage_identity:
            raise InstallError('Stage directory entry changed.')
        os.fchmod(stage, 0o555)
        os.fsync(stage)
        rename_no_replace(parent, stage_name, TARGET_NAME)
        published = True
        os.fsync(parent)
        require_directory_identity(runtime_path, parent)
        target = os.stat(TARGET_NAME, dir_fd=parent, follow_symlinks=False)
        if (target.st_dev, target.st_ino) != stage_identity:
            raise InstallError('Published directory entry changed.')
        return runtime_path + '/' + TARGET_NAME
    except BaseException as error:
        if stage_name is not None:
            state = 'Complete publication retained in original held parent.' if published else 'Private stage retained in original held parent: ' + stage_name
            raise InstallError(str(error) + '\n' + state) from error
        raise
    finally:
        if stage is not None:
            os.close(stage)
        if parent is not None:
            os.close(parent)
        os.close(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, help='Existing absolute directory; no symlink components.')
    parser.add_argument('--runtime-directory', required=True, help='Existing absolute runtime parent; target structured-ocr must be absent.')
    parser.add_argument('--expected-manifest-sha256', required=True, help='Digest reviewed by the caller; does not activate an unknown core digest.')
    args = parser.parse_args()
    try:
        print(install(args.source, args.runtime_directory, args.expected_manifest_sha256))
    except (InstallError, OSError, ValueError, AttributeError, RecursionError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
