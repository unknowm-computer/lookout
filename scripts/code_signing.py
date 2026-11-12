#!/usr/bin/env python3
"""Lookout's fixed local signing identity. Private material never enters the repo."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SIGNING_DIR = Path.home() / 'Library/Application Support/Lookout/Signing'
CONFIG = ROOT / 'Resources/SigningIdentity.plist'
IDENTIFIERS = {
    'app': 'local.lookout.app',
    'fan': 'local.lookout.fan-helper',
    'window': 'local.lookout.window-helper',
}
COMPONENTS = {
    'app': '',
    'fan': 'Contents/Library/Helpers/LookoutFanHelper',
    'window': 'Contents/Library/LoginItems/LookoutWindowHelper.app',
}


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or 'Code signing command failed.')
    return result.stdout.strip()


def load_identity(config=CONFIG):
    if not config.is_file():
        raise ValueError('고정 서명 설정이 없습니다. 최초 서명 Mac에서 bash scripts/setup-local-signing.sh를 실행하세요.')
    with config.open('rb') as source:
        value = plistlib.load(source)
    identity = value.get('CertificateSHA1', '')
    if value.get('BundleIdentifier') != IDENTIFIERS['app'] or not re.fullmatch(r'[A-F0-9]{40}', identity):
        raise ValueError('Lookout의 고정 서명 설정이 유효하지 않습니다.')
    return identity


def local_identity(directory=SIGNING_DIR):
    for name in ('identity.sha1', 'certificate.cer', 'Lookout.keychain-db', 'password'):
        if not (directory / name).is_file():
            raise ValueError('Lookout 전용 서명 키가 없습니다. 기존 서명 Mac을 사용하세요. 임시 서명으로 전환하지 않습니다.')
    identity = (directory / 'identity.sha1').read_text().strip()
    actual = hashlib.sha1((directory / 'certificate.cer').read_bytes()).hexdigest().upper()
    if not re.fullmatch(r'[A-F0-9]{40}', identity) or identity != actual:
        raise ValueError('Lookout의 공개 인증서와 저장된 지문이 다릅니다.')
    return identity


def requirement(kind, identity):
    return f'identifier "{IDENTIFIERS[kind]}" and certificate leaf = H"{identity}"'


def designated_requirement(path):
    result = subprocess.run(['codesign', '-d', '-r-', str(path)], capture_output=True, text=True, check=True)
    match = re.search(r'^(?:# )?designated => (.+)$', result.stdout + '\n' + result.stderr, re.MULTILINE)
    if not match:
        raise ValueError(f'코드 서명 식별 조건이 없습니다: {path}')
    return match.group(1)


def verify(path, kind, identity):
    run('codesign', '--verify', '--all-architectures', '--deep', '--strict',
        '-R=' + requirement(kind, identity), path)
    if 'cdhash' in designated_requirement(path):
        raise ValueError(f'업데이트 간 유지되는 고정 서명이 아닙니다: {path}')


def sign(path, kind, identity, directory=SIGNING_DIR):
    # No hardened runtime / library validation: a self-signed identity has no Apple Team ID.
    run('codesign', '--force', '--options=0', '--timestamp=none', '--sign', identity,
        '--keychain', directory / 'Lookout.keychain-db', '--identifier', IDENTIFIERS[kind], path)
    verify(path, kind, identity)


def prepare():
    identity = load_identity()
    if local_identity() != identity:
        raise ValueError('이 Mac의 서명 키가 프로젝트에 고정된 인증서와 다릅니다. 기존 키를 교체하지 않습니다.')
    helper = ROOT / '.build/tools/signing-keychain'
    source = ROOT / 'scripts/signing-keychain.swift'
    helper.parent.mkdir(parents=True, exist_ok=True)
    if not helper.exists() or source.stat().st_mtime > helper.stat().st_mtime:
        run('xcrun', 'swiftc', '-suppress-warnings', source, '-o', helper)
    run(helper, 'unlock', SIGNING_DIR)
    # Verifies the private key is available before modifying any build output.
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', SIGNING_DIR / 'Lookout.keychain-db')
    if not re.search(r'\b' + identity + r'\b', identities):
        raise ValueError('고정 인증서의 유효한 개인 키를 찾지 못했습니다. 기존 앱을 보존합니다.')
    return identity


def pin():
    """Explicit initial setup only; never replace an existing pinned certificate."""
    identity = local_identity(SIGNING_DIR)
    if CONFIG.exists():
        if load_identity(CONFIG) != identity:
            raise ValueError('기존 프로젝트 서명 신원을 변경하지 않습니다.')
    else:
        with CONFIG.open('xb') as output:
            plistlib.dump({'BundleIdentifier': IDENTIFIERS['app'], 'CertificateSHA1': identity}, output)
    print('Lookout 공개 인증서 지문 고정 완료.')


def verify_bundle(app, identity):
    for kind, relative in COMPONENTS.items():
        verify(app / relative, kind, identity)


def verify_update(previous, updated, identity):
    verify_bundle(previous, identity)
    verify_bundle(updated, identity)
    for relative in COMPONENTS.values():
        old, new = previous / relative, updated / relative
        # Check both directions, including app and each independent helper identity.
        for origin, target in ((old, new), (new, old)):
            run('codesign', '--verify', '--all-architectures', '--strict',
                '-R=' + designated_requirement(origin), target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('prepare')
    sub.add_parser('pin')
    for command in ('sign', 'verify'):
        item = sub.add_parser(command)
        item.add_argument('path', type=Path)
        item.add_argument('--kind', choices=IDENTIFIERS, default='app')
    sub.add_parser('verify-bundle').add_argument('path', type=Path)
    update = sub.add_parser('verify-update')
    update.add_argument('previous', type=Path)
    update.add_argument('updated', type=Path)
    args = parser.parse_args()
    if args.command == 'pin':
        pin()
    elif args.command == 'prepare':
        prepare()
    else:
        identity = load_identity()
        if args.command == 'sign':
            sign(args.path, args.kind, prepare())
        elif args.command == 'verify':
            verify(args.path, args.kind, identity)
        elif args.command == 'verify-bundle':
            verify_bundle(args.path, identity)
        else:
            verify_update(args.previous, args.updated, identity)
        print('고정 코드 서명 검증 완료.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
