#!/usr/bin/env python3
"""Exercise pip's hash enforcement offline using a disposable wheel."""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.request
import zipfile


class SimulatorInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.wheel = self.root / 'herm_fixture-1.0-py3-none-any.whl'
        with zipfile.ZipFile(self.wheel, 'w') as wheel:
            wheel.writestr('herm_fixture.py', 'value = 1\n')
            wheel.writestr('herm_fixture-1.0.dist-info/METADATA',
                           'Metadata-Version: 2.1\nName: herm-fixture\nVersion: 1.0\n')
            wheel.writestr('herm_fixture-1.0.dist-info/WHEEL',
                           'Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n')
            wheel.writestr('herm_fixture-1.0.dist-info/RECORD', '')
        self.digest = hashlib.sha256(self.wheel.read_bytes()).hexdigest()

    def install(self, requirement):
        lock = self.root / 'requirements.txt'
        lock.write_text(requirement + '\n')
        return subprocess.run(
            [sys.executable, '-m', 'pip', '--isolated', 'install', '--no-index',
             '--find-links', str(self.root), '--require-hashes', '--only-binary=:all:',
             '--target', str(self.root / 'target'), '-r', str(lock)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)

    def test_valid_hash_is_accepted(self):
        result = self.install('herm-fixture==1.0 --hash=sha256:' + self.digest)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_changed_wheel_is_rejected(self):
        with self.wheel.open('ab') as wheel:
            wheel.write(b'tampered')
        result = self.install('herm-fixture==1.0 --hash=sha256:' + self.digest)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('do not match the hashes', result.stdout.lower())

    def test_missing_hash_is_rejected(self):
        result = self.install('herm-fixture==1.0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('hashes are required', result.stdout.lower())

    def test_unpinned_requirement_is_rejected(self):
        result = self.install('herm-fixture')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must have their versions pinned', result.stdout)

    def test_shell_install_failure_stops_before_resource_copy(self):
        fake = self.root / 'python3'
        fake.write_text(
            '#!/bin/sh\n'
            'if [ "$2" = venv ]; then\n'
            '  mkdir -p "$3/bin"\n'
            '  cp "$0" "$3/bin/python3"\n'
            '  exit 0\n'
            'fi\n'
            'printf "%s\\n" "$@" > "$CAPTURE"\n'
            'exit 1\n'
        )
        fake.chmod(0o755)
        env = os.environ.copy()
        env['PATH'] = str(self.root) + os.pathsep + env['PATH']
        env['HERM_SIMULATOR_ENV'] = str(self.root / 'environment')
        env['CAPTURE'] = str(self.root / 'arguments')
        script = pathlib.Path(__file__).resolve().parent / 'setup-simulator-bridge.sh'
        result = subprocess.run([str(script)], env=env, capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        args = (self.root / 'arguments').read_text().splitlines()
        self.assertIn('--isolated', args)
        self.assertIn('--require-hashes', args)
        self.assertIn('--only-binary=:all:', args)
        self.assertEqual(pathlib.Path(args[args.index('-r') + 1]).resolve(),
                         script.parent.parent / 'Sources/Herm/Resources/SimulatorBridge/requirements.lock')
        self.assertFalse((self.root / 'environment/resources').exists())
        self.assertNotIn('installed.', result.stdout)

    def test_locked_hashes_match_pypi_wheels(self):
        lock = (pathlib.Path(__file__).resolve().parent.parent /
                'Sources/Herm/Resources/SimulatorBridge/requirements.lock').read_text()
        for entry in lock.replace('\\\n', '').splitlines():
            match = re.match(r'([\w-]+)==([^\s]+)', entry)
            self.assertIsNotNone(match)
            assert match is not None
            name, version = match.groups()
            expected = set(re.findall(r'--hash=sha256:([0-9a-f]{64})', entry))
            with urllib.request.urlopen(f'https://pypi.org/pypi/{name}/{version}/json', timeout=30) as response:
                files = json.load(response)['urls']
            wheels = {item['digests']['sha256'] for item in files if item['filename'].endswith('.whl')}
            self.assertTrue(expected, name)
            self.assertFalse(expected - wheels, name)


if __name__ == '__main__':
    unittest.main()
