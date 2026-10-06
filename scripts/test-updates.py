#!/usr/bin/env python3
"""Test build injection and GitHub appcast contracts without accessing private keys."""
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

from update_config import ROOT, load_configuration

spec = importlib.util.spec_from_file_location('prepare_release', ROOT / 'scripts/prepare-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class UpdateDistributionTests(unittest.TestCase):
    def setUp(self):
        self.config = load_configuration({})
        self.info = {
            'CFBundleIdentifier': 'local.lookout.app',
            'CFBundleShortVersionString': '0.6.0',
            'CFBundleVersion': '6',
            'LSMinimumSystemVersion': '15.0',
            'SUFeedURL': self.config['feedURL'],
            'SUPublicEDKey': self.config['publicKey'],
        }

    def inject(self, updates):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / 'source.plist', Path(directory) / 'output.plist'
            source.write_bytes(plistlib.dumps(self.info))
            environment = {key: value for key, value in os.environ.items() if not key.startswith('LOOKOUT_')}
            environment.update(updates)
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/configure-updates.py'), str(source), str(output)],
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(plistlib.loads(source.read_bytes()), self.info)
            return result, plistlib.loads(output.read_bytes()) if output.exists() else None

    def test_default_build_uses_current_repository_and_key(self):
        result, info = self.inject({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(info['SUFeedURL'], 'https://github.com/unknowm-computer/lookout/releases/latest/download/appcast.xml')
        self.assertEqual(info['SUPublicEDKey'], self.config['publicKey'])

    def test_overrides_replace_both_values(self):
        key = base64.b64encode(bytes(32)).decode()
        result, info = self.inject({'LOOKOUT_UPDATE_FEED_URL': 'https://example.com/appcast.xml', 'LOOKOUT_UPDATE_PUBLIC_KEY': key})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(info['SUFeedURL'], 'https://example.com/appcast.xml')
        self.assertEqual(info['SUPublicEDKey'], key)

    def test_partial_override_does_not_mix_with_project_key(self):
        for values in [{'LOOKOUT_UPDATE_FEED_URL': 'https://example.com/feed'}, {'LOOKOUT_UPDATE_PUBLIC_KEY': self.config['publicKey']}]:
            result, info = self.inject(values)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(info)

    def test_explicit_disable_removes_stale_settings(self):
        result, info = self.inject({'LOOKOUT_DISABLE_UPDATES': '1'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('SUFeedURL', info)
        self.assertNotIn('SUPublicEDKey', info)
        self.assertEqual(info['CFBundleVersion'], '6')

    def test_disable_and_override_are_rejected(self):
        with self.assertRaises(ValueError):
            load_configuration({'LOOKOUT_DISABLE_UPDATES': '1', 'LOOKOUT_UPDATE_FEED_URL': self.config['feedURL'], 'LOOKOUT_UPDATE_PUBLIC_KEY': self.config['publicKey']})

    def test_invalid_feed_and_key_are_rejected(self):
        for feed in ['http://example.com/feed', 'https://user:pass@example.com/feed', 'https://example.com/feed#fragment', 'https:///feed']:
            with self.assertRaises(ValueError):
                load_configuration({'LOOKOUT_UPDATE_FEED_URL': feed, 'LOOKOUT_UPDATE_PUBLIC_KEY': self.config['publicKey']})
        with self.assertRaises(ValueError):
            load_configuration({'LOOKOUT_UPDATE_FEED_URL': self.config['feedURL'], 'LOOKOUT_UPDATE_PUBLIC_KEY': base64.b64encode(bytes(31)).decode()})

    def test_remote_formats_and_unexpected_host(self):
        for remote in ['https://github.com/unknowm-computer/lookout.git', 'git@github.com:unknowm-computer/lookout.git', 'https://github.com/unknowm-computer/lookout']:
            self.assertEqual(release.github_repository(remote), self.config['repository'])
        with self.assertRaises(ValueError):
            release.github_repository('https://example.com/unknowm-computer/lookout.git')

    def test_feed_targets_immutable_zip_and_matching_bundle_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'Lookout-0.6.0.zip'
            archive.write_bytes(b'archive contents')
            signature = base64.b64encode(bytes(64)).decode()
            tree = release.make_appcast(self.info, self.config, archive, signature)
            item = tree.find('./channel/item')
            namespace = {'sparkle': release.SPARKLE}
            self.assertEqual(item.find('sparkle:version', namespace).text, '6')
            self.assertEqual(item.find('sparkle:shortVersionString', namespace).text, '0.6.0')
            self.assertEqual(item.find('sparkle:minimumSystemVersion', namespace).text, '15.0')
            enclosure = item.find('enclosure')
            self.assertEqual(enclosure.get('url'), 'https://github.com/unknowm-computer/lookout/releases/download/v0.6.0/Lookout-0.6.0.zip')
            self.assertEqual(int(enclosure.get('length')), archive.stat().st_size)
            self.assertEqual(enclosure.get(f'{{{release.SPARKLE}}}edSignature'), signature)
            with self.assertRaises(ValueError):
                release.make_appcast(self.info, self.config, archive, base64.b64encode(bytes(32)).decode())

    def test_release_rejects_app_with_wrong_key_feed_or_version(self):
        for key, value in [('SUPublicEDKey', base64.b64encode(bytes(32)).decode()), ('SUFeedURL', 'https://example.com/feed'), ('CFBundleIdentifier', 'other.app'), ('CFBundleVersion', ''), ('CFBundleShortVersionString', '../0.6.0'), ('LSMinimumSystemVersion', '')]:
            with self.assertRaises(ValueError):
                release.validate_bundle({**self.info, key: value}, self.config)


if __name__ == '__main__':
    unittest.main(verbosity=2)
