#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('helper_artifacts', Path(__file__).with_name('package-helpers.py'))
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)

class HelperArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.write('scripts/build.sh', 'build flags')
        self.package = {'name': 'Fixture', 'toolsVersion': {'_version': '6.0.0'}, 'platforms': [],
            'products': [], 'targets': [
                {'name': name, 'type': 'executable' if name.startswith('Lookout') else 'regular',
                 'dependencies': [{'byName': [dep, None]} for dep in deps]}
                for name, deps in [('LookoutFanHelper', ['FanSupport']), ('FanSupport', []),
                                   ('LookoutWindowHelper', ['WindowLayoutModel']), ('WindowLayoutModel', []), ('Lookout', [])]]}
        for target in self.package['targets']:
            self.write(f'Sources/{target["name"]}/main.swift', target['name'])
        for _, _, resources in helpers.KINDS.values():
            for path in resources: self.write(path, path)
    def write(self, path, value):
        file = self.root / path; file.parent.mkdir(parents=True, exist_ok=True); file.write_text(value)
    def key(self, kind='fan', toolchain='toolchain'):
        return helpers.fingerprint(self.root, self.package, kind, toolchain)
    def test_app_ui_localization_and_version_do_not_change_helper_keys(self):
        keys = [self.key(kind) for kind in helpers.KINDS]
        self.write('Sources/Lookout/main.swift', 'UI edit')
        self.write('Sources/LookoutCore/Resources/ko.lproj/Localizable.strings', 'new string')
        self.write('Resources/Info.plist', 'new app version')
        self.package['targets'][-1]['swiftSettings'] = ['new app setting']
        self.assertEqual(keys, [self.key(kind) for kind in helpers.KINDS])
    def test_transitive_helper_source_changes_only_its_artifact(self):
        fan, window = self.key('fan'), self.key('window')
        self.write('Sources/FanSupport/main.swift', 'new policy')
        self.assertNotEqual(fan, self.key('fan')); self.assertEqual(window, self.key('window'))
    def test_new_dependency_is_automatically_included(self):
        before = self.key()
        self.package['targets'][1]['dependencies'].append({'byName': ['NewShared', None]})
        self.package['targets'].append({'name': 'NewShared', 'type': 'regular', 'dependencies': []})
        self.write('Sources/NewShared/value.swift', 'shared')
        self.assertNotEqual(before, self.key())
        before = self.key(); self.write('Sources/NewShared/value.swift', 'changed')
        self.assertNotEqual(before, self.key())
    def test_external_dependency_fails_closed(self):
        self.package['targets'][1]['dependencies'].append({'product': ['Unknown', 'External', None, None]})
        with self.assertRaises(ValueError): self.key()
    def test_launch_plist_resources_and_toolchain_invalidate(self):
        for resource in helpers.KINDS['window'][2]:
            before = self.key('window'); self.write(resource, 'changed')
            self.assertNotEqual(before, self.key('window'))
        self.assertNotEqual(self.key(), self.key(toolchain='new compiler'))
    def test_reuses_exact_signed_bytes_and_rejects_corrupted_cache(self):
        cache, app = self.root / 'cache', self.root / 'App'
        builds = []
        def prepare(root, bin_dir, stage, kind):
            builds.append(kind)
            product = helpers.KINDS[kind][0]
            result = stage / (product + ('.app' if kind == 'window' else ''))
            if kind == 'window':
                result.mkdir(); (result / 'signed').write_bytes(b'window signature')
            else: result.write_bytes(b'fan signature')
            return result
        with patch.object(helpers, 'prepare', side_effect=prepare), patch.object(helpers, 'verify'):
            def package(): helpers.package_helpers(self.root, self.root, app, self.package, cache, 'toolchain')
            package(); expected = helpers.tree(app)
            package(); self.assertEqual(builds, ['fan', 'window']); self.assertEqual(expected, helpers.tree(app))
            artifact = next(cache.glob('fan/*/LookoutFanHelper')); artifact.write_bytes(b'corrupted')
            with self.assertRaises(ValueError): package()

if __name__ == '__main__': unittest.main()
