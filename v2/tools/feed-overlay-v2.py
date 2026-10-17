#!/usr/bin/env python3
"""Verify the pinned NSS feed, and apply new files from v2/feed-overlay/ if there are any.

The NSS feed is used as he pins it. v2/feed-overlay/ (absent now) holds new files only, never a
change to one of his: an earlier candidate carried an ECM patch there and raised ECM's package
release so its packages were not taken for that candidate's; his ECM has moved well past that
release since. With --check, the prepared feed must be the pinned commit plus the overlay
files, and nothing else.
"""
import argparse
from pathlib import Path
import shutil
import subprocess

V2 = Path(__file__).resolve().parents[1]
OVERLAY = V2 / 'feed-overlay'


def overlay_files():
    return sorted(path for path in OVERLAY.rglob('*') if path.is_file()) if OVERLAY.is_dir() else []


def check_or_apply(tree, check=False):
    feed = tree / 'feeds/nss'
    lock = dict(line.split() for line in (V2 / 'feeds.lock').read_text().splitlines()
                if line.strip() and not line.lstrip().startswith('#'))
    actual = subprocess.check_output(['git', '-C', str(feed), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != lock['nss']:
        raise ValueError('NSS feed does not match its pinned commit')
    changes = []
    for source in overlay_files():
        relative = source.relative_to(OVERLAY)
        destination = tree / 'feeds' / relative
        if destination.exists():
            if destination.read_bytes() != source.read_bytes():
                raise ValueError('feed overlay filename collision: ' + str(relative))
        elif check:
            raise ValueError('prepared tree is missing feed overlay: ' + str(relative))
        else:
            changes.append((source, destination))
    if check:
        ours = {str(path.relative_to(OVERLAY / 'nss')) for path in overlay_files()}
        status = subprocess.check_output(['git', '-C', str(feed), 'status', '--porcelain',
                                          '--untracked-files=all'], text=True)
        for line in status.splitlines():
            state, name = line[:2], line[3:]
            if state == '??' and name in ours:
                continue
            raise ValueError('NSS feed differs from its pin outside the overlay: ' + line)
    else:
        for source, destination in changes:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    return {'nss_commit': actual,
            'overlay': [str(path.relative_to(OVERLAY)) for path in overlay_files()]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tree', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    print(check_or_apply(args.tree.resolve(), args.check))


if __name__ == '__main__':
    main()
