import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).with_name('install_linux_ocr_runtime.py')
spec = importlib.util.spec_from_file_location('installer', SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class RuntimeInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pmt-installer-test-')
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.parent = self.root / 'runtime'
        self.source.mkdir()
        self.parent.mkdir()
        self.contents = {'bin/python3.12': b'#!/bin/sh\nexit 0\n', 'models/sub/data.bin': b'PINNED MODEL\0\xff'}
        for name, payload in self.contents.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            path.chmod(0o6755 if name.startswith('bin/') else 0o666)
        self.document = {'schemaVersion': 1, 'backend': 'docling', 'qualifiedAdapterVersion': 1,
                         'files': {name: {'sha256': hashlib.sha256(payload).hexdigest(), 'byteCount': len(payload)}
                                   for name, payload in self.contents.items()}}
        self.save_manifest()

    def tearDown(self):
        # Nur die eigenen Fixtures entsperren, ohne Symlinkziele zu betreten.
        for directory, directories, files in os.walk(self.root, followlinks=False):
            os.chmod(directory, 0o700)
            for name in files:
                path = Path(directory) / name
                if not path.is_symlink():
                    path.chmod(0o600)
        self.temporary.cleanup()

    def save_manifest(self, raw=None):
        payload = raw if raw is not None else json.dumps(self.document).encode()
        (self.source / installer.MANIFEST_NAME).write_bytes(payload)
        self.digest = hashlib.sha256(payload).hexdigest()

    def run_cli(self, source=None, parent=None, digest=None):
        return subprocess.run([sys.executable, str(SCRIPT), '--source', str(source or self.source),
                               '--runtime-directory', str(parent or self.parent),
                               '--expected-manifest-sha256', digest or self.digest], capture_output=True, text=True, timeout=5)

    def rejected(self, **kwargs):
        result = self.run_cli(**kwargs)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.parent / installer.TARGET_NAME).exists())
        return result

    def test_valid_hash_permissions_and_no_source_changes(self):
        original = {name: (self.source / name).read_bytes() for name in self.contents}
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        target = self.parent / installer.TARGET_NAME
        for name, payload in self.contents.items():
            self.assertEqual((target / name).read_bytes(), payload)
            self.assertEqual((self.source / name).read_bytes(), original[name])
            self.assertEqual(stat.S_IMODE((target / name).stat().st_mode), 0o555 if name.startswith('bin/') else 0o444)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o555)
        self.assertEqual(hashlib.sha256((target / installer.MANIFEST_NAME).read_bytes()).hexdigest(), self.digest)
        self.assertFalse(list(self.parent.glob('.pmt-structured-ocr-*')))

    def test_adapter_two_preserves_verified_manifest(self):
        self.document['qualifiedAdapterVersion'] = 2
        self.save_manifest()
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.parent / installer.TARGET_NAME / installer.MANIFEST_NAME).read_bytes(),
                         (self.source / installer.MANIFEST_NAME).read_bytes())

    def test_unknown_or_untyped_adapter_is_rejected(self):
        for version in [0, 3, True, '2']:
            with self.subTest(version=version):
                self.document['qualifiedAdapterVersion'] = version
                self.save_manifest()
                self.rejected()

    def test_collision_directory_preserved(self):
        target = self.parent / installer.TARGET_NAME
        target.mkdir()
        (target / 'foreign').write_bytes(b'KEEP')
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((target / 'foreign').read_bytes(), b'KEEP')
        self.assertFalse(list(self.parent.glob('.pmt-structured-ocr-*')))

    def test_collision_empty_directory_preserved(self):
        target = self.parent / installer.TARGET_NAME
        target.mkdir()
        inode = target.stat().st_ino
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertEqual(target.stat().st_ino, inode)
        self.assertEqual(list(target.iterdir()), [])

    def test_collision_link_preserved(self):
        foreign = self.root / 'foreign'
        foreign.write_bytes(b'KEEP')
        target = self.parent / installer.TARGET_NAME
        target.symlink_to(foreign)
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertTrue(target.is_symlink())
        self.assertEqual(foreign.read_bytes(), b'KEEP')

    def test_source_root_alias_rejected(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.source, target_is_directory=True)
        self.rejected(source=alias)

    def test_target_ancestor_alias_rejected(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        self.rejected(parent=alias / self.parent.name)

    def test_deep_source_alias_rejected(self):
        original = self.source / 'models/sub'
        original.rename(self.root / 'sub')
        original.symlink_to(self.root / 'sub', target_is_directory=True)
        self.rejected()

    def test_source_fifo_does_not_block(self):
        path = self.source / 'models/sub/data.bin'
        path.unlink()
        os.mkfifo(path)
        self.rejected()

    def test_manifest_fifo_does_not_block(self):
        path = self.source / installer.MANIFEST_NAME
        path.unlink()
        os.mkfifo(path)
        self.rejected()

    def test_source_hardlink_rejected(self):
        os.link(self.source / 'models/sub/data.bin', self.root / 'alias.bin')
        self.rejected()

    def test_unknown_file_rejected(self):
        (self.source / 'extra').write_text('not in manifest')
        self.rejected()

    def test_unknown_empty_directory_rejected(self):
        (self.source / 'extra').mkdir()
        self.rejected()

    def test_source_corruption_rejected(self):
        (self.source / 'models/sub/data.bin').write_bytes(b'CHANGED MODEL!\xff')
        self.rejected()

    def test_manifest_digest_rejected_before_parse(self):
        self.save_manifest(raw=b'invalid JSON')
        result = self.rejected(digest='0' * 64)
        self.assertIn('SHA256 differs', result.stderr)

    def test_duplicate_root_key_rejected(self):
        raw=json.dumps(self.document).encode().replace(b'"schemaVersion": 1', b'"schemaVersion": 1, "schemaVersion": 1')
        self.save_manifest(raw)
        self.assertIn('Duplicate JSON key', self.rejected().stderr)

    def test_duplicate_nested_key_rejected(self):
        raw=json.dumps(self.document).encode().replace(b'"byteCount": 17', b'"byteCount": 17, "byteCount": 17')
        # Das erste Binary hat 17 Bytes; die Gegenprobe muss wirklich einen doppelten Schlüssel enthalten.
        self.assertNotEqual(raw, json.dumps(self.document).encode())
        self.save_manifest(raw)
        self.assertIn('Duplicate JSON key', self.rejected().stderr)

    def test_ambiguous_manifest_paths_rejected(self):
        record = self.document['files']['models/sub/data.bin']
        for path in ['../escape', '/absolute', 'bin//bad', './bad', 'bin/../bad', 'nul\0bad', 'back\\slash']:
            with self.subTest(path=path):
                self.document['files'] = {'bin/python3.12': self.document['files']['bin/python3.12'], path: record}
                self.save_manifest()
                self.rejected()

    def test_manifest_limits_and_boolean_byte_count_rejected(self):
        for count in [True, -1, installer.MAX_TOTAL_BYTES + 1]:
            with self.subTest(count=count):
                self.document['files']['models/sub/data.bin']['byteCount'] = count
                self.save_manifest()
                self.rejected()

    def test_oversized_manifest_rejected_without_parse(self):
        self.save_manifest(raw=b' ' * (installer.MAX_MANIFEST_BYTES + 1))
        self.assertIn('exceeds 8 MiB', self.rejected().stderr)

    def test_file_count_limit_rejected(self):
        record = {'sha256': '0' * 64, 'byteCount': 0}
        self.document['files'] = {'file' + str(index): record for index in range(installer.MAX_FILES + 1)}
        self.save_manifest()
        self.assertIn('32768 files', self.rejected().stderr)

    def test_total_size_limit_rejected(self):
        for record in self.document['files'].values():
            record['byteCount'] = installer.MAX_TOTAL_BYTES // 2 + 1
        self.save_manifest()
        self.assertIn('exceeds 4 GiB', self.rejected().stderr)

    def test_missing_declared_file_rejected(self):
        (self.source / 'models/sub/data.bin').unlink()
        self.rejected()

    def test_python_must_be_executable(self):
        (self.source / 'bin/python3.12').chmod(0o644)
        self.rejected()

    def test_staged_content_change_is_not_published(self):
        original = installer.verify_stage_tree
        def corrupt(stage, prefix, files, directories, seen):
            if not prefix:
                os.chmod('bin/python3.12', 0o644, dir_fd=stage)
                descriptor = os.open('bin/python3.12', os.O_WRONLY, dir_fd=stage)
                os.write(descriptor, b'BAD'); os.close(descriptor)
                os.chmod('bin/python3.12', 0o555, dir_fd=stage)
            original(stage, prefix, files, directories, seen)
        with mock.patch.object(installer, 'verify_stage_tree', corrupt):
            with self.assertRaises(installer.InstallError):
                installer.install(str(self.source), str(self.parent), self.digest)
        self.assertFalse((self.parent / installer.TARGET_NAME).exists())

    def test_target_appearing_at_rename_is_preserved(self):
        original = installer.rename_no_replace
        def create_collision(parent, source, target):
            os.mkdir(target, dir_fd=parent)
            fd = os.open(target, installer.DIRECTORY_FLAGS, dir_fd=parent)
            try:
                file = os.open('foreign', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=fd)
                os.write(file, b'KEEP'); os.close(file)
            finally:
                os.close(fd)
            original(parent, source, target)
        with mock.patch.object(installer, 'rename_no_replace', create_collision):
            with self.assertRaises(installer.InstallError):
                installer.install(str(self.source), str(self.parent), self.digest)
        self.assertEqual((self.parent / installer.TARGET_NAME / 'foreign').read_bytes(), b'KEEP')

    def test_parent_rename_before_publication_rejected(self):
        original = installer.copy_file
        moved = self.root / 'moved'
        triggered = False
        def move_parent(*args):
            nonlocal triggered
            result = original(*args)
            if not triggered:
                self.parent.rename(moved); self.parent.mkdir(); triggered = True
            return result
        with mock.patch.object(installer, 'copy_file', move_parent):
            with self.assertRaises(installer.InstallError):
                installer.install(str(self.source), str(self.parent), self.digest)
        self.assertFalse((self.parent / installer.TARGET_NAME).exists())
        self.assertFalse((moved / installer.TARGET_NAME).exists())
        self.assertTrue(list(moved.glob('.pmt-structured-ocr-*')))

    def test_parent_rename_at_publication_uses_held_parent(self):
        original = installer.rename_no_replace
        moved = self.root / 'moved'
        def move_parent(parent, source, target):
            self.parent.rename(moved); self.parent.mkdir()
            original(parent, source, target)
        with mock.patch.object(installer, 'rename_no_replace', move_parent):
            with self.assertRaises(installer.InstallError):
                installer.install(str(self.source), str(self.parent), self.digest)
        self.assertFalse((self.parent / installer.TARGET_NAME).exists())
        for name, payload in self.contents.items():
            self.assertEqual((moved / installer.TARGET_NAME / name).read_bytes(), payload)


    def test_relative_utf8_byte_and_depth_boundaries(self):
        parts = ['é' * 31] * 64
        parts[-1] += 'x' * 65
        boundary = '/'.join(parts)
        self.assertEqual(len(boundary.encode('utf-8')), 4096)
        self.assertEqual(len(installer.relative_components(boundary)), 64)
        with self.assertRaisesRegex(installer.InstallError, '4096 UTF-8 bytes'):
            installer.relative_components(boundary + 'x')
        self.assertEqual(len(installer.relative_components('/'.join(['a'] * 64))), 64)
        with self.assertRaisesRegex(installer.InstallError, '64 components'):
            installer.relative_components('/'.join(['a'] * 65))

    def test_absolute_utf8_byte_boundary_before_filesystem_access(self):
        parts = ['é' * 31] * 63 + ['é' * 63]
        boundary = '/' + '/'.join(parts)
        self.assertEqual(len(boundary.encode('utf-8')), 4096)
        self.assertEqual(installer.normalized_absolute(boundary), parts)
        with self.assertRaisesRegex(installer.InstallError, '4096 UTF-8 bytes'):
            installer.normalized_absolute(boundary + 'x')
        for key in ['source', 'parent']:
            with self.subTest(argument=key):
                result = self.rejected(**{key: boundary + 'x'})
                self.assertIn('4096 UTF-8 bytes', result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                self.assertFalse(list(self.parent.glob('.pmt-structured-ocr-*')))

    def test_invalid_utf8_absolute_arguments_rejected_without_traceback(self):
        for key in ['source', 'parent']:
            with self.subTest(argument=key):
                value = os.fsdecode(os.fsencode(self.root) + b'/invalid-\xff')
                result = self.rejected(**{key: value})
                self.assertIn('valid UTF-8', result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                self.assertFalse(list(self.parent.glob('.pmt-structured-ocr-*')))

    def test_overbudget_or_non_utf8_manifest_paths_reject_before_stage(self):
        record = self.document['files']['models/sub/data.bin']
        base = {'bin/python3.12': self.document['files']['bin/python3.12']}
        oversized = '/'.join(['é' * 31] * 64) + 'x' * 66
        self.assertEqual(len(oversized.encode('utf-8')), 4097)
        for path, diagnostic in [(oversized, '4096 UTF-8 bytes'),
                                 ('/'.join(['a'] * 65), '64 components'),
                                 ('invalid-\udcff', 'valid UTF-8')]:
            with self.subTest(diagnostic=diagnostic):
                self.document['files'] = {**base, path: record}
                self.save_manifest()
                result = self.rejected()
                self.assertIn(diagnostic, result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                self.assertFalse(list(self.parent.glob('.pmt-structured-ocr-*')))

    def test_derived_directory_budget_exact_boundary_and_rejection(self):
        record = {'sha256': hashlib.sha256(b'').hexdigest(), 'byteCount': 0}
        files = {'bin/python3.12': self.document['files']['bin/python3.12']}
        for index in range(1040):
            files['/'.join([f'branch{index}'] + ['d'] * 62 + ['data.bin'])] = record
        files['/'.join(['boundary'] + ['d'] * 14 + ['data.bin'])] = record
        # 1040 unabhängige Äste à 63 Verzeichnisse, 15 weitere und bin.
        self.assertEqual(1040 * 63 + 15 + 1, 65536)
        self.document['files'] = files
        self.save_manifest()
        source = installer.open_directory(str(self.source))
        try:
            _, parsed_files, directories, _ = installer.read_manifest(source, self.digest)
        finally:
            os.close(source)
        self.assertEqual(len(parsed_files), 1042)
        self.assertEqual(len(directories) - 1, 65536)
        self.document['files']['one-more/data.bin'] = record
        self.save_manifest()
        result = self.rejected()
        self.assertIn('65536 derived directories', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse(list(self.parent.glob('.pmt-structured-ocr-*')))

    def test_excessively_nested_json_has_controlled_cli_error(self):
        payload = b'{"nested":' + b'[' * 2000 + b'0' + b']' * 2000 + b'}'
        self.save_manifest(payload)
        result = self.rejected()
        self.assertTrue('JSON exceeds the parser nesting limit' in result.stderr or 'Unsupported runtime manifest schema' in result.stderr, result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual((self.source / installer.MANIFEST_NAME).read_bytes(), payload)
        self.assertFalse(list(self.parent.glob('.pmt-structured-ocr-*')))

    def test_json_recursion_error_becomes_install_error_on_all_python_versions(self):
        source = installer.open_directory(str(self.source))
        try:
            with mock.patch.object(installer.json, 'loads', side_effect=RecursionError('decoder nesting')):
                with self.assertRaisesRegex(installer.InstallError, 'JSON exceeds the parser nesting limit'):
                    installer.read_manifest(source, self.digest)
        finally:
            os.close(source)
        self.assertFalse(list(self.parent.glob('.pmt-structured-ocr-*')))


    def exhaust_directory_cursor(self, descriptor):
        library = ctypes.CDLL(None, use_errno=True)
        library.fdopendir.argtypes = [ctypes.c_int]
        library.fdopendir.restype = ctypes.c_void_p
        library.readdir.argtypes = [ctypes.c_void_p]
        library.readdir.restype = ctypes.c_void_p
        library.closedir.argtypes = [ctypes.c_void_p]
        library.closedir.restype = ctypes.c_int
        os.lseek(descriptor, 0, os.SEEK_SET)
        duplicate = os.dup(descriptor)
        directory = library.fdopendir(duplicate)
        if not directory:
            os.close(duplicate)
            self.fail('fdopendir failed')
        count = 0
        try:
            ctypes.set_errno(0)
            while library.readdir(directory):
                count += 1
            self.assertEqual(ctypes.get_errno(), 0)
        finally:
            self.assertEqual(library.closedir(directory), 0)
        return count

    def test_listing_ignores_and_preserves_existing_directory_cursor(self):
        descriptor = installer.open_directory(str(self.source))
        try:
            self.assertEqual(self.exhaust_directory_cursor(descriptor), 5)
            before = os.lseek(descriptor, 0, os.SEEK_CUR)
            self.assertNotEqual(before, 0)
            self.assertEqual(set(installer.directory_names(descriptor)),
                             {'bin', 'models', installer.MANIFEST_NAME})
            self.assertEqual(os.lseek(descriptor, 0, os.SEEK_CUR), before)
        finally:
            os.close(descriptor)

    def test_install_verifies_every_file_with_stage_cursor_at_eof(self):
        original = installer.verify_stage_tree
        exhausted = []
        def verify(stage, prefix, files, directories, seen):
            if not prefix:
                exhausted.append(self.exhaust_directory_cursor(stage))
                before = os.lseek(stage, 0, os.SEEK_CUR)
                self.assertNotEqual(before, 0)
                original(stage, prefix, files, directories, seen)
                self.assertEqual(os.lseek(stage, 0, os.SEEK_CUR), before)
                self.assertEqual(seen, set(files))
            else:
                original(stage, prefix, files, directories, seen)
        with mock.patch.object(installer, 'verify_stage_tree', verify):
            result = installer.install(str(self.source), str(self.parent), self.digest)
        self.assertEqual(exhausted, [5])
        for name, payload in self.contents.items():
            self.assertEqual((Path(result) / name).read_bytes(), payload)


if __name__ == '__main__':
    unittest.main(verbosity=2)
