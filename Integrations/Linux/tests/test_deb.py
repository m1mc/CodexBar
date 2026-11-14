from pathlib import Path
import subprocess
import platform
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


class DebianPackageTests(unittest.TestCase):
    def test_deb_contains_launcher_and_runtime_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['python3', str(REPO / 'Integrations/Linux/package_deb.py'),
                            '--binary', '/usr/bin/true', '--version', '0.0.0-test',
                            '--output', str(root)], check=True, capture_output=True)
            package = next(root.glob('*.deb'))
            self.assertRegex(package.name, r'^CodexBarDesktop-v0\.0\.0-test-linux-(amd64|arm64)\.deb$')

            info = subprocess.check_output(['dpkg-deb', '--info', str(package)], text=True)
            self.assertIn('Package: codexbar-desktop', info)
            self.assertIn('Version: 0.0.0-test', info)
            architecture = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(platform.machine())
            self.assertIn(f'Architecture: {architecture}', info)
            self.assertIn('Depends: libc6', info)

            contents = subprocess.check_output(['dpkg-deb', '--contents', str(package)], text=True)
            for path in [
                './usr/bin/codexbar-linux',
                './usr/share/applications/codexbar.desktop',
                './usr/share/icons/hicolor/scalable/apps/codexbar.svg',
                './usr/share/doc/codexbar-desktop/THIRD_PARTY_NOTICES',
            ]:
                self.assertIn(path, contents)

            desktop = subprocess.check_output(
                ['dpkg-deb', '--fsys-tarfile', str(package)], text=False)
            self.assertIn(b'Exec=codexbar-linux', desktop)

    def test_deb_rejects_invalid_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            for version in ['../escape', 'v1.2.3', '1.0;command', '1.0\nother']:
                result = subprocess.run(['python3', str(REPO / 'Integrations/Linux/package_deb.py'),
                                         '--binary', '/usr/bin/true', '--version', version,
                                         '--output', temporary],
                                        capture_output=True)
                self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(Path(temporary).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
