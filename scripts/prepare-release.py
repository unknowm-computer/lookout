#!/usr/bin/env python3
"""Build local GitHub Release assets; never upload files or export private keys."""
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import quote
import xml.etree.ElementTree as ET

from update_config import ROOT, load_configuration

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def github_repository(remote):
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?/?', remote.strip())
    if not match:
        raise ValueError('origin must be a GitHub HTTPS or SSH repository URL.')
    return match.group(1)


def validate_bundle(info, config):
    if info.get('CFBundleIdentifier') != 'local.lookout.app':
        raise ValueError('Unexpected app Bundle ID.')
    for plist_key, config_key in [('SUFeedURL', 'feedURL'), ('SUPublicEDKey', 'publicKey')]:
        if info.get(plist_key) != config[config_key]:
            raise ValueError(f'The built app has a different {plist_key}; rebuild with the release configuration.')
    version = str(info.get('CFBundleShortVersionString', ''))
    build = str(info.get('CFBundleVersion', ''))
    minimum = str(info.get('LSMinimumSystemVersion', ''))
    if not all(re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', value) for value in (version, build, minimum)):
        raise ValueError('App version, build number and minimum macOS version must be numeric dotted versions.')
    return version, build, minimum


def make_appcast(info, config, archive, signature):
    version, build, minimum = validate_bundle(info, config)
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid Ed25519 archive signature.')
    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Lookout Updates'
    ET.SubElement(channel, 'link').text = f"https://github.com/{config['repository']}/releases"
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Lookout {version}'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = minimum
    ET.SubElement(item, 'enclosure', {
        'url': f"https://github.com/{config['repository']}/releases/download/v{version}/{quote(archive.name)}",
        'length': str(archive.stat().st_size),
        'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature,
    })
    ET.indent(rss)
    return ET.ElementTree(rss)


def run(*arguments, capture=False):
    environment = os.environ.copy()
    developer = Path('/Applications/Xcode.app/Contents/Developer')
    if 'DEVELOPER_DIR' not in environment and developer.is_dir():
        environment['DEVELOPER_DIR'] = str(developer)
    result = subprocess.run(arguments, cwd=ROOT, env=environment, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def prepare_release():
    config = load_configuration()
    repository = github_repository(run('git', 'remote', 'get-url', 'origin', capture=True))
    if repository != config['repository']:
        raise ValueError('origin and Resources/UpdateConfiguration.json refer to different repositories.')
    expected_feed = f'https://github.com/{repository}/releases/latest/download/appcast.xml'
    if config['feedURL'] != expected_feed:
        raise ValueError('Release preparation requires the configured GitHub latest-release appcast URL.')
    # Resolve tools if this is a new checkout, before looking up the signing key.
    tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
    if not (tools / 'generate_keys').is_file():
        run('xcrun', 'swift', 'package', 'resolve')
    account = config['keychainAccount']
    public_key = run(str(tools / 'generate_keys'), '--account', account, '-p', capture=True)
    if public_key != config['publicKey']:
        raise ValueError('The Keychain public key does not match the public key shipped in Lookout. Use the original signing key; do not replace it for an existing release.')
    run('bash', 'scripts/create-dmg.sh')
    app = ROOT / 'build/Lookout.app'
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    version, build, _ = validate_bundle(info, config)
    destination = ROOT / 'build/releases' / f'v{version}-build{build}'
    # Avoid accidentally replacing files whose signatures/URLs may already be published.
    if destination.exists():
        raise ValueError(f'{destination} already exists. Increase the app version/build for a new release, or move the unpublished local folder before retrying.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='release.', dir=destination.parent) as staging:
        folder = Path(staging)
        archive = folder / f'Lookout-{version}.zip'
        run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive))
        signature = run(str(tools / 'sign_update'), '--account', account, '-p', str(archive), capture=True)
        run(str(tools / 'sign_update'), '--account', account, '--verify', str(archive), signature)
        make_appcast(info, config, archive, signature).write(folder / 'appcast.xml', encoding='utf-8', xml_declaration=True)
        shutil.copy2(ROOT / 'build' / f'Lookout-{version}.dmg', folder)
        assets = sorted(folder.iterdir())
        checksums = ''.join(f'{hashlib.sha256(asset.read_bytes()).hexdigest()}  {asset.name}\n' for asset in assets)
        (folder / 'SHA256SUMS.txt').write_text(checksums, encoding='utf-8')
        shutil.move(str(folder), str(destination))
    print(f'Prepared {destination}')
    print(f'GitHub Release tag: v{version} (build {build})')
    print('Upload the ZIP, DMG, appcast.xml and SHA256SUMS.txt together as a normal latest release.')
    print('No files were uploaded. The updater feed becomes available after publishing the release.')


if __name__ == '__main__':
    try:
        prepare_release()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
