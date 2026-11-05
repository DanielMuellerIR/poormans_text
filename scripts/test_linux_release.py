import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class LinuxReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='pmt-release-crypto-')
        cls.work = Path(cls.temporary.name)
        cls.home = cls.work/'gnupg'
        cls.home.mkdir(mode=0o700)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.addClassCleanup(subprocess.run, ['gpgconf', '--homedir', str(cls.home), '--kill', 'gpg-agent'],
                            capture_output=True, timeout=10)
        cls.environment = dict(os.environ, GNUPGHOME=str(cls.home))
        subprocess.run(['gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase', '',
                        '--quick-generate-key', 'PMT disposable release test', 'ed25519', 'sign', '0'],
                       env=cls.environment, capture_output=True, check=True, timeout=30)
        listing = subprocess.check_output(['gpg', '--batch', '--with-colons', '--list-keys'], env=cls.environment, text=True)
        cls.fingerprint = next(line.split(':')[9] for line in listing.splitlines() if line.startswith('fpr:'))
        cls.keyring = cls.work/'public.gpg'
        cls.keyring.write_bytes(subprocess.check_output(['gpg', '--batch', '--export', cls.fingerprint], env=cls.environment))

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(prefix='case-', dir=self.work)
        self.root = Path(self.case.name)
        self.artifact = self.root/'Paket ü.zip'
        self.artifact.write_bytes(b'actual package bytes\0\xff')

    def tearDown(self):
        self.case.cleanup()

    def run_script(self, script, *args, environment=None):
        return subprocess.run([str(ROOT/script), *map(str, args)], env=environment or self.environment,
                              capture_output=True, text=True, timeout=30)

    def sign(self, path=None):
        result = self.run_script('sign-linux.sh', path or self.artifact, '--key', self.fingerprint)
        self.assertEqual(result.returncode, 0, result.stderr)

    def verify(self, fingerprint=None):
        return self.run_script('verify-linux-release.sh', self.artifact, '--keyring', self.keyring,
                               '--fingerprint', fingerprint or self.fingerprint)

    def test_linux_wrapper_defaults_and_cli_only(self):
        isolated = self.root/'wrapper test'
        (isolated/'scripts').mkdir(parents=True)
        stub = '#!/usr/bin/python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n'
        for target in ['build.sh', 'scripts/package_linux.sh']:
            path = isolated/target
            path.write_text(stub)
            path.chmod(0o755)
        for name, arguments in [('build-linux.sh', ['release']),
                                ('release-linux.sh', ['--no-build', '--format', 'zip'])]:
            path = isolated/name
            shutil.copy2(ROOT/name, path)
            for extra, expected in [([], ['--with-gui', *arguments]), (['--cli-only'], arguments)]:
                result = subprocess.run([str(path), *extra, *arguments], capture_output=True, text=True, check=True)
                self.assertEqual(json.loads(result.stdout), expected)

    def test_real_signature_tampering_and_wrong_signer(self):
        self.sign()
        self.assertEqual(self.verify().returncode, 0)
        self.assertNotEqual(self.verify('0'*40).returncode, 0)
        self.artifact.write_bytes(b'changed bytes')
        self.assertNotEqual(self.verify().returncode, 0)

    def test_existing_signature_and_source_are_preserved(self):
        self.sign()
        signature = self.artifact.with_name(self.artifact.name+'.sig')
        original = signature.read_bytes()
        self.assertEqual(self.run_script('sign-linux.sh', self.artifact, '--key', self.fingerprint).returncode, 73)
        self.assertEqual(signature.read_bytes(), original)
        self.assertEqual(self.artifact.read_bytes(), b'actual package bytes\0\xff')

    def test_links_and_fifo_reject_without_publication(self):
        alias = self.root/'alias.zip'
        alias.symlink_to(self.artifact)
        self.assertNotEqual(self.run_script('sign-linux.sh', alias, '--key', self.fingerprint).returncode, 0)
        fifo = self.root/'fifo'
        os.mkfifo(fifo)
        self.assertNotEqual(self.run_script('sign-linux.sh', fifo, '--key', self.fingerprint).returncode, 0)
        parent = self.root/'alias-parent'
        parent.symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(self.run_script('sign-linux.sh', parent/self.artifact.name, '--key', self.fingerprint).returncode, 0)
        self.assertFalse(self.artifact.with_name(self.artifact.name+'.sig').exists())

    def test_explicit_key_required(self):
        result = self.run_script('sign-linux.sh', self.artifact, '--key', 'default')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.artifact.with_name(self.artifact.name+'.sig').exists())

    def package_fixture(self, package_name='poormans-text'):
        tree = self.root/'deb-source'
        (tree/'DEBIAN').mkdir(parents=True)
        (tree/'DEBIAN/control').write_text(f'Package: {package_name}\nVersion: 1.0\nArchitecture: amd64\nMaintainer: Test\nDescription: synthetic package\n')
        package = self.root/'test.deb'
        subprocess.run(['dpkg-deb', '--build', str(tree), str(package)], capture_output=True, check=True)
        return package

    def fake_manager_environment(self, name='apt-get'):
        tools = self.root/'tools'
        tools.mkdir()
        manager = tools/name
        manager.write_text('#!/usr/bin/python3\nimport json,os,sys,pathlib\np=pathlib.Path(sys.argv[-1]);pathlib.Path(os.environ["PMT_CAPTURE"]).write_text(json.dumps({"args":sys.argv[1:],"size":p.stat().st_size,"signed":p.with_name(p.name+".sig").exists()}))\n')
        manager.chmod(0o755)
        sudo = tools/'sudo'
        sudo.write_text('#!/bin/sh\n[ "$1" = -- ] && shift\nexec "$@"\n')
        sudo.chmod(0o755)
        return dict(self.environment, PATH=str(tools)+':'+os.environ['PATH'], PMT_CAPTURE=str(self.root/'capture.json'))

    def test_installer_verified_staging_and_native_arguments(self):
        package = self.package_fixture()
        self.sign(package)
        environment = self.fake_manager_environment()
        result = self.run_script('install-linux.sh', '--package', package, '--keyring', self.keyring,
                                 '--fingerprint', self.fingerprint, environment=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads((self.root/'capture.json').read_text())
        self.assertEqual(capture['args'][:2], ['install', '--'])
        self.assertNotEqual(capture['args'][-1], str(package))
        self.assertTrue(capture['signed'])
        self.assertFalse(Path(capture['args'][-1]).exists())

    def test_installer_rejects_foreign_package_before_manager(self):
        package = self.package_fixture('other-program')
        result = self.run_script('install-linux.sh', '--package', package, environment=self.fake_manager_environment())
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'capture.json').exists())

    def test_installer_tamper_prevents_execution(self):
        package = self.package_fixture()
        self.sign(package)
        self.artifact = package
        result = self.run_script('install-linux.sh', '--package', package, '--keyring', self.keyring,
                                 '--fingerprint', '0'*40, environment=self.fake_manager_environment())
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'capture.json').exists())

    def test_pacman_staging_retains_native_signature(self):
        metadata = self.root/'.PKGINFO'
        metadata.write_text('pkgname = poormans-text\npkgver = 1.0-1\narch = x86_64\n')
        package = self.root/'test.pkg.tar.zst'
        subprocess.run(['tar', '--zstd', '-cf', str(package), '-C', str(self.root), '.PKGINFO'], check=True)
        self.sign(package)
        result = self.run_script('install-linux.sh', '--package', package, '--keyring', self.keyring,
                                 '--fingerprint', self.fingerprint, environment=self.fake_manager_environment('pacman'))
        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads((self.root/'capture.json').read_text())
        self.assertEqual(capture['args'][:2], ['-U', '--'])
        self.assertTrue(capture['signed'])
        self.assertFalse(Path(capture['args'][-1]).exists())

    def test_dry_run_does_not_invoke_manager(self):
        package = self.package_fixture()
        result = self.run_script('install.sh', '--package', package, '--dry-run', environment=self.fake_manager_environment())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('install --', result.stdout)
        self.assertFalse((self.root/'capture.json').exists())


if __name__ == '__main__':
    unittest.main()
