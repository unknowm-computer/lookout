#!/usr/bin/env python3
"""Package/reuse signed helpers by their complete local dependency inputs.

The cache is a build artifact, never an authorization source. Runtime peer signature
checks and macOS approval remain authoritative. Keep this cache across app releases.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

KINDS = {
    'fan': ('LookoutFanHelper', 'Contents/Library/Helpers/LookoutFanHelper',
            ['Resources/local.lookout.fan-helper.plist']),
    'window': ('LookoutWindowHelper', 'Contents/Library/LoginItems/LookoutWindowHelper.app',
               ['Resources/local.lookout.window-helper.plist', 'Resources/WindowHelper-Info.plist', 'Resources/WindowHelper.icns']),
}

def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def tree(path):
    files = sorted(path.rglob('*')) if path.is_dir() else [path]
    result = {}
    for file in files:
        if file.is_symlink():
            raise ValueError(f'Symlinks are not supported in helper artifacts: {file}')
        if file.is_file():
            result[str(file.relative_to(path)) if path.is_dir() else '.'] = [digest(file), stat.S_IMODE(file.stat().st_mode)]
    return result

def dependency_inputs(root, package, product):
    targets = {target['name']: target for target in package['targets']}
    closure = {}
    def visit(name):
        if name in closure:
            return
        target = targets[name]
        if target.get('pluginUsages') or target.get('type') not in ('regular', 'executable'):
            raise ValueError(f'Unsupported helper dependency: {name}')
        closure[name] = target
        for dependency in target.get('dependencies', []):
            value = dependency.get('byName', dependency.get('target'))
            if not value or value[0] not in targets:
                raise ValueError(f'External helper dependency needs an explicit cache policy: {dependency}')
            visit(value[0])
    visit(product)
    files = {}
    for name, target in closure.items():
        folder = (root / (target.get('path') or f'Sources/{name}')).resolve()
        folder.relative_to(root.resolve())
        files[name] = tree(folder)
    return {'targets': closure, 'files': files,
            'package': {key: value for key, value in package.items() if key not in ('targets', 'products', 'dependencies', 'packageKind')}}

def fingerprint(root, package, kind, toolchain):
    product, _, resources = KINDS[kind]
    inputs = dependency_inputs(root, package, product)
    inputs.update(toolchain=toolchain, recipe=digest(Path(__file__)), buildScript=digest(root / 'scripts/build.sh'),
                  resources={file: digest(root / file) for file in resources},
                  build='release;arm64+x86_64;strip=-x,-S;sign=adhoc;v1')
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()

def verify(path, kind):
    run('codesign', '--verify', '--deep', '--strict', str(path))
    binary = path / 'Contents/MacOS/LookoutWindowHelper' if kind == 'window' else path
    for architecture in ('arm64', 'x86_64'):
        run('xcrun', 'lipo', str(binary), '-verify_arch', architecture)

def prepare(root, bin_dir, stage, kind):
    product, _, _ = KINDS[kind]
    output = stage / product
    if kind == 'window':
        output = stage / (product + '.app')
        (output / 'Contents/MacOS').mkdir(parents=True)
        (output / 'Contents/Resources').mkdir()
        shutil.copy2(root / 'Resources/WindowHelper-Info.plist', output / 'Contents/Info.plist')
        shutil.copy2(root / 'Resources/WindowHelper.icns', output / 'Contents/Resources/AppIcon.icns')
        binary = output / 'Contents/MacOS/LookoutWindowHelper'
    else:
        binary = output
    shutil.copy2(bin_dir / product, binary)
    run('xcrun', 'strip', '-x', '-S', str(binary))
    signing = ['codesign', '--force', '--sign', '-']
    if kind == 'fan':
        signing += ['--identifier', 'local.lookout.fan-helper']
    run(*signing, str(output))
    verify(output, kind)
    return output

def package_helpers(root, bin_dir, app, package, cache, toolchain):
    for kind, (product, relative, resources) in KINDS.items():
        key = fingerprint(root, package, kind, toolchain)
        entry = cache / kind / key
        artifact_name = product + ('.app' if kind == 'window' else '')
        artifact = entry / artifact_name
        if entry.exists():
            manifest = json.loads((entry / 'manifest.json').read_text())
            if manifest != {'fingerprint': key, 'files': tree(artifact)}:
                raise ValueError(f'Helper cache validation failed: {entry}')
            verify(artifact, kind)
            print(f'Reusing signed {product}: {key[:12]}', flush=True)
        else:
            entry.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='.staging-', dir=entry.parent) as temporary:
                staging = Path(temporary)
                built = prepare(root, bin_dir, staging, kind)
                (staging / 'manifest.json').write_text(json.dumps({'fingerprint': key, 'files': tree(built)}, sort_keys=True))
                staging.rename(entry)
            print(f'Cached signed {product}: {key[:12]}', flush=True)
        destination = app / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Fresh inode, without modifying or re-signing the cached helper.
        with tempfile.TemporaryDirectory(prefix='.helper-', dir=destination.parent) as temporary:
            staged = Path(temporary) / artifact_name
            if artifact.is_dir():
                shutil.copytree(artifact, staged)
            else:
                shutil.copy2(artifact, staged)
            verify(staged, kind)
            if destination.is_dir():
                shutil.rmtree(destination)
            elif destination.exists():
                destination.unlink()
            staged.rename(destination)
        plist = Path(resources[0])
        plist_folder = app / ('Contents/Library/LaunchDaemons' if kind == 'fan' else 'Contents/Library/LaunchAgents')
        plist_folder.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / plist, plist_folder / plist.name)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bin-dir', required=True, type=Path)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--package', required=True, type=Path)
    parser.add_argument('--cache', type=Path, default=Path(os.environ.get('LOOKOUT_HELPER_CACHE', '.helper-artifacts')))
    args = parser.parse_args()
    toolchain = [run('xcrun', 'swift', '--version'), run('xcodebuild', '-version'),
                 run('xcrun', '--sdk', 'macosx', '--show-sdk-build-version')]
    package_helpers(Path.cwd(), args.bin_dir, args.app, json.loads(args.package.read_text()), args.cache, toolchain)

if __name__ == '__main__':
    main()
