#!/usr/bin/env python3
"""Exercise the distributed installer in temporary destinations, never /Applications."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / 'build/Lookout.app'
INSTALLER = ROOT / 'scripts/Install Lookout.command'


def run(*args):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lookout-installer-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.dmg = self.root / 'DMG with spaces'
        self.dmg.mkdir()
        self.source = self.dmg / 'Lookout.app'
        copied = run('/usr/bin/ditto', str(APP), str(self.source))
        self.assertEqual(copied.returncode, 0, copied.stderr)
        self.script = self.dmg / INSTALLER.name
        shutil.copy2(INSTALLER, self.script)
        self.destination = self.root / 'Applications with spaces'
        self.target = self.destination / 'Lookout.app'
        self.settings = self.root / 'saved-settings.json'
        self.settings.write_text('{"interval":3,"storageInterval":1800}')

    def install(self):
        return run('/bin/bash', str(self.script), '--destination', str(self.destination), '--no-launch')

    def existing(self):
        self.destination.mkdir()
        result = run('/usr/bin/ditto', str(APP), str(self.target))
        self.assertEqual(result.returncode, 0, result.stderr)
        # An old-only resource must survive failures and disappear on successful replacement.
        (self.target / 'old-version-marker').write_text('original')

    def assert_clean(self):
        self.assertEqual(list(self.destination.glob('.Lookout-install*')), [])
        self.assertEqual(self.settings.read_text(), '{"interval":3,"storageInterval":1800}')

    def test_fresh_install_removes_only_installed_quarantine_and_preserves_other_attributes(self):
        for path in [self.source, self.source / 'Contents/MacOS/Lookout', self.script]:
            result = run('/usr/bin/xattr', '-w', 'com.apple.quarantine', '0083;00000000;LookoutInstallerTest;', str(path))
            self.assertEqual(result.returncode, 0, result.stderr)
        result = run('/usr/bin/xattr', '-w', 'com.lookout.installer-test', 'preserve-me', str(self.source))
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for path in [self.target, self.target / 'Contents/MacOS/Lookout']:
            self.assertNotEqual(run('/usr/bin/xattr', '-p', 'com.apple.quarantine', str(path)).returncode, 0)
        self.assertEqual(run('/usr/bin/xattr', '-p', 'com.apple.quarantine', str(self.source)).returncode, 0)
        self.assertEqual(run('/usr/bin/xattr', '-p', 'com.apple.quarantine', str(self.script)).returncode, 0)
        self.assertEqual(run('/usr/bin/xattr', '-p', 'com.lookout.installer-test', str(self.target)).stdout.strip(), 'preserve-me')
        self.assertEqual(run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(self.target)).returncode, 0)
        self.assert_clean()

    def test_update_replaces_old_app_and_preserves_settings(self):
        self.existing()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.target / 'old-version-marker').exists())
        self.assert_clean()

    def test_damaged_new_app_does_not_replace_existing_app(self):
        self.existing()
        with (self.source / 'Contents/MacOS/Lookout').open('ab') as binary:
            binary.write(b'tampered')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.target / 'old-version-marker').read_text(), 'original')
        self.assert_clean()

    def test_different_existing_bundle_is_not_replaced(self):
        self.existing()
        info = self.target / 'Contents/Info.plist'
        with info.open('rb') as file:
            contents = plistlib.load(file)
        contents['CFBundleIdentifier'] = 'unrelated.app'
        with info.open('wb') as file:
            plistlib.dump(contents, file)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Bundle ID', result.stderr)
        self.assertEqual((self.target / 'old-version-marker').read_text(), 'original')
        self.assert_clean()

    def test_destination_symlink_and_install_lock_are_not_overwritten(self):
        self.destination.mkdir()
        self.target.symlink_to(self.source, target_is_directory=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.target.is_symlink())
        self.target.unlink()
        lock = self.destination / '.Lookout-install.lock'
        lock.mkdir()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lock.is_dir())
        self.assertFalse(self.target.exists())

    def test_failed_replacement_restores_backup_and_cleans_temporary_files(self):
        self.existing()
        # Inject a failed filesystem move only into the fixture copy of the installer.
        text = self.script.read_text()
        operation = '/bin/mv "$task_staged_app" "$task_target"'
        self.assertEqual(text.count(operation), 1)
        self.script.write_text(text.replace(operation, '/usr/bin/false'))
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('기존 Lookout을 복구', result.stderr)
        self.assertEqual((self.target / 'old-version-marker').read_text(), 'original')
        self.assert_clean()

    def test_failed_final_verification_restores_the_previous_app(self):
        self.existing()
        text = self.script.read_text()
        operation = '/usr/bin/codesign --verify --deep --strict "$task_target"'
        self.assertEqual(text.count(operation), 1)
        self.script.write_text(text.replace(operation, '/usr/bin/false'))
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.target / 'old-version-marker').read_text(), 'original')
        self.assert_clean()

    def test_stops_only_the_app_at_the_install_destination(self):
        self.existing()
        processes = []
        try:
            for app in [self.target, self.source]:
                process = subprocess.Popen([str(app / 'Contents/MacOS/Lookout'), '--probe'],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                processes.append(process)
            for _ in range(20):
                command = run('/bin/ps', '-p', str(processes[0].pid), '-o', 'comm=').stdout.strip()
                if command == str(self.target / 'Contents/MacOS/Lookout'):
                    break
                time.sleep(0.05)
            self.assertIsNone(processes[0].poll())
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(processes[0].wait(timeout=2), -15)
            self.assertIsNone(processes[1].poll(), 'Another copy of Lookout must keep running')
            self.assert_clean()
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=3)


if __name__ == '__main__':
    if not APP.is_dir():
        raise SystemExit('Run bash scripts/build.sh before testing the installer.')
    unittest.main(verbosity=2)
