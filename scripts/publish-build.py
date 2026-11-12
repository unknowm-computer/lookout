#!/usr/bin/env python3
"""Atomically stage a verified app, preserving the previous build on failure."""
from pathlib import Path
import shutil
import sys
import tempfile

import code_signing


def publish(source, destination):
    identity = code_signing.load_identity()
    code_signing.verify_bundle(source, identity)
    if destination.is_symlink():
        raise ValueError('심볼릭 링크인 빌드 앱을 교체하지 않습니다.')
    if destination.exists():
        previous = code_signing.designated_requirement(destination)
        # The initial ad-hoc -> certificate migration is intentional. Once fixed,
        # every later build must satisfy the previous app AND helper requirements.
        if 'cdhash' not in previous:
            code_signing.verify_update(destination, source, identity)
    temporary = Path(tempfile.mkdtemp(prefix='.previous-', dir=destination.parent))
    backup = temporary / destination.name
    try:
        if destination.exists():
            destination.rename(backup)
        try:
            source.rename(destination)
        except OSError:
            if backup.exists():
                # If rollback itself fails, leave the backup directory intact.
                try:
                    backup.rename(destination)
                except OSError as error:
                    raise ValueError(f'기존 빌드 복구 실패. 백업 보존: {backup}') from error
            raise
    except Exception:
        if not backup.exists():
            shutil.rmtree(temporary)
        raise
    shutil.rmtree(temporary)


if __name__ == '__main__':
    publish(Path(sys.argv[1]), Path(sys.argv[2]))
