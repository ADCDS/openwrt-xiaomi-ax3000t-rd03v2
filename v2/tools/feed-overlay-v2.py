#!/usr/bin/env python3
"""Apply or verify new patch files on the pinned NSS feed.

The overlay is empty since 0053 was dropped (the QinQ failure it worked around was the
AN8855 RX length, fixed by kernel patch 0959e). ECM keeps a release above rc1's, whose
release 2 carried 0053, so the package of a later build is never taken for rc1's.
"""
import argparse
from pathlib import Path
import shutil
import subprocess

V2 = Path(__file__).resolve().parents[1]


def check_or_apply(tree, check=False):
    feed = tree / 'feeds/nss'
    lock = dict(line.split() for line in (V2 / 'feeds.lock').read_text().splitlines()
                if line.strip() and not line.lstrip().startswith('#'))
    actual = subprocess.check_output(['git', '-C', str(feed), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != lock['nss']:
        raise ValueError('NSS feed does not match its pinned commit')
    original = subprocess.check_output(['git', '-C', str(feed), 'show', 'HEAD:qca-nss-ecm/Makefile'])
    anchor = b'PKG_RELEASE:=1\n'
    if original.count(anchor) != 1:
        raise ValueError('NSS ECM package release anchor changed; review the overlay')
    desired = original.replace(anchor, b'PKG_RELEASE:=3\n')
    makefile = feed / 'qca-nss-ecm/Makefile'
    if makefile.read_bytes() not in (original, desired):
        raise ValueError('NSS ECM package contains unexpected local changes')
    changes = []
    for source in sorted((V2 / 'feed-overlay').rglob('*')):
        if not source.is_file():
            continue
        relative = source.relative_to(V2 / 'feed-overlay')
        destination = tree / 'feeds' / relative
        if destination.exists():
            if destination.read_bytes() != source.read_bytes():
                raise ValueError('feed overlay filename collision: ' + str(relative))
        elif check:
            raise ValueError('prepared tree is missing feed overlay: ' + str(relative))
        else:
            changes.append((source, destination))
    if check:
        if makefile.read_bytes() != desired:
            raise ValueError('prepared NSS ECM package release is not 3')
        # Nothing else may differ from the pinned feed: a patch dropped from the overlay
        # (0053) must not survive in a tree prepared before.
        overlay = {str(path.relative_to(V2 / 'feed-overlay' / 'nss'))
                   for path in (V2 / 'feed-overlay').rglob('*') if path.is_file()}
        status = subprocess.check_output(['git', '-C', str(feed), 'status', '--porcelain',
                                          '--untracked-files=all'], text=True)
        for line in status.splitlines():
            state, name = line[:2], line[3:]
            if (state.strip(), name) == ('M', 'qca-nss-ecm/Makefile'):
                continue
            if state == '??' and name in overlay:
                continue
            raise ValueError('NSS feed differs from its pin outside the overlay: ' + line)
    else:
        for source, destination in changes:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        makefile.write_bytes(desired)
    return {'nss_commit': actual, 'ecm_package_release': 3,
            'patches': [str(path.relative_to(V2 / 'feed-overlay')) for path in sorted((V2 / 'feed-overlay').rglob('*.patch'))]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tree', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    print(check_or_apply(args.tree.resolve(), args.check))


if __name__ == '__main__':
    main()
