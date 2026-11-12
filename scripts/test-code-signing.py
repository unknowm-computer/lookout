#!/usr/bin/env python3
"""Signing policy tests; --integration signs disposable probes with the existing key."""
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import code_signing as signing

spec = importlib.util.spec_from_file_location('publish_build', Path(__file__).with_name('publish-build.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)

INTEGRATION = '--integration' in sys.argv
if INTEGRATION:
    sys.argv.remove('--integration')


class SigningPolicyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.config = self.root / 'SigningIdentity.plist'

    def write_config(self, identity='A' * 40, bundle='local.lookout.app'):
        self.config.write_bytes(plistlib.dumps({'BundleIdentifier': bundle, 'CertificateSHA1': identity}))

    def test_missing_or_invalid_pin_does_not_fall_back_to_adhoc(self):
        with self.assertRaises(ValueError):
            signing.load_identity(self.config)
        self.assertFalse(self.config.exists())
        for identity, bundle in [('-', 'local.lookout.app'), ('A' * 40, 'com.linelens.app')]:
            self.write_config(identity, bundle)
            with self.assertRaises(ValueError):
                signing.load_identity(self.config)

    def test_local_certificate_must_match_its_fingerprint_and_have_keychain(self):
        certificate = b'public certificate fixture'
        identity = hashlib.sha1(certificate).hexdigest().upper()
        for name, value in [('certificate.cer', certificate), ('identity.sha1', identity.encode()),
                            ('password', b'test-only-password')]:
            (self.root / name).write_bytes(value)
        with self.assertRaises(ValueError):
            signing.local_identity(self.root)
        (self.root / 'Lookout.keychain-db').write_bytes(b'test-only-keychain')
        self.assertEqual(signing.local_identity(self.root), identity)
        (self.root / 'identity.sha1').write_text('B' * 40)
        with self.assertRaises(ValueError):
            signing.local_identity(self.root)

    def test_setup_never_overwrites_existing_project_identity(self):
        self.write_config()
        before = self.config.read_bytes()
        with patch.object(signing, 'CONFIG', self.config), patch.object(signing, 'local_identity', return_value='B' * 40):
            with self.assertRaises(ValueError):
                signing.pin()
        self.assertEqual(self.config.read_bytes(), before)

    def test_requirement_parser_accepts_both_codesign_output_formats(self):
        for prefix in ('', '# '):
            reply = subprocess.CompletedProcess([], 0, '', prefix + 'designated => identifier "fixture"\n')
            with patch.object(signing.subprocess, 'run', return_value=reply):
                self.assertEqual(signing.designated_requirement(self.root), 'identifier "fixture"')

    def publication_fixture(self):
        old, new = self.root / 'Lookout.app', self.root / 'Staged.app'
        for path, text in ((old, 'old'), (new, 'new')):
            path.mkdir()
            (path / 'payload').write_text(text)
        for name, value in [('load_identity', 'A' * 40), ('verify_bundle', None),
                            ('designated_requirement', 'identifier "local.lookout.app"'), ('verify_update', None)]:
            patched = patch.object(signing, name, return_value=value)
            patched.start()
            self.addCleanup(patched.stop)
        return old, new

    def test_invalid_signature_and_changed_identity_keep_previous_build(self):
        old, new = self.publication_fixture()
        for check in ('verify_bundle', 'verify_update'):
            with patch.object(signing, check, side_effect=ValueError('rejected')):
                with self.assertRaises(ValueError):
                    publisher.publish(new, old)
            self.assertEqual((old / 'payload').read_text(), 'old')
            self.assertTrue(new.is_dir())

    def test_failed_publish_rolls_back_previous_build(self):
        old, new = self.publication_fixture()
        rename = Path.rename
        def fail_new(path, target):
            if path == new:
                raise OSError('simulated move failure')
            return rename(path, target)
        with patch.object(Path, 'rename', fail_new), self.assertRaises(OSError):
            publisher.publish(new, old)
        self.assertEqual((old / 'payload').read_text(), 'old')
        self.assertEqual(list(self.root.glob('.previous-*')), [])

    def test_failed_rollback_preserves_recoverable_backup(self):
        old, new = self.publication_fixture()
        rename = Path.rename
        def fail_after_backup(path, target):
            if path == new or path.parent.name.startswith('.previous-'):
                raise OSError('simulated move failure')
            return rename(path, target)
        with patch.object(Path, 'rename', fail_after_backup), self.assertRaises(ValueError):
            publisher.publish(new, old)
        backup = list(self.root.glob('.previous-*/Lookout.app/payload'))
        self.assertEqual(len(backup), 1)
        self.assertEqual(backup[0].read_text(), 'old')

    def test_successful_publish_checks_previous_identity_and_replaces_build(self):
        old, new = self.publication_fixture()
        publisher.publish(new, old)
        signing.verify_update.assert_called_once_with(old, new, 'A' * 40)
        self.assertEqual((old / 'payload').read_text(), 'new')
        self.assertEqual(list(self.root.glob('.previous-*')), [])

    @unittest.skipUnless(INTEGRATION, 'Pass --integration on the signing Mac.')
    def test_changed_code_keeps_identity_but_wrong_identifier_or_adhoc_is_rejected(self):
        identity = signing.prepare()
        for kind in signing.IDENTIFIERS:
            probes = []
            for version in (1, 2):
                source, output = self.root / f'{kind}{version}.c', self.root / f'{kind}{version}'
                source.write_text(f'int main(void) {{ return {version}; }}\n')
                signing.run('xcrun', 'clang', '-arch', 'arm64', '-arch', 'x86_64', source, '-o', output)
                signing.sign(output, kind, identity)
                probes.append(output)
            self.assertNotEqual(probes[0].read_bytes(), probes[1].read_bytes())
            old, new = map(signing.designated_requirement, probes)
            self.assertEqual(old, new)
            self.assertNotIn('cdhash', new)
            for target, requirement in ((probes[0], new), (probes[1], old)):
                signing.run('codesign', '--verify', '--all-architectures', '--strict', '-R=' + requirement, target)
            other = 'fan' if kind != 'fan' else 'window'
            with self.assertRaises(ValueError):
                signing.verify(probes[0], other, identity)
            signing.run('codesign', '--force', '--sign', '-', probes[1])
            with self.assertRaises(ValueError):
                signing.verify(probes[1], kind, identity)


if __name__ == '__main__':
    unittest.main()
