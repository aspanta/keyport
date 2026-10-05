#!/usr/bin/env python3
"""Generate old download paths from the canonical Linux client; --check for CI."""
import argparse
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = (
    'bin/keyport-client',
    'bin/keyport-client-update',
    'keyport-client-install',
    'keyport-client.conf.example',
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if compatibility files differ')
    args = parser.parse_args()
    mismatches = []
    for name in FILES:
        source = ROOT / 'clients/linux' / name
        target = ROOT / 'clients/debian' / name
        if args.check:
            if (not target.is_file() or source.read_bytes() != target.read_bytes()
                    or source.stat().st_mode & 0o777 != target.stat().st_mode & 0o777):
                mismatches.append(name)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            target.chmod(source.stat().st_mode & 0o777)
    if mismatches:
        print('Outdated Linux compatibility files: ' + ', '.join(mismatches), file=sys.stderr)
        print('Run: python3 scripts/sync-linux-compat.py', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
