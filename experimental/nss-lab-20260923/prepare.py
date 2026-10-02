#!/usr/bin/env python3
"""Restore the pinned experimental source inputs into a NEW Linux build tree."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent

def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def config_values(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines()
                if line.startswith('CONFIG_') and '=' in line)

def safe_relative(value):
    path = Path(value)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError(f'Unsafe overlay path: {value}')
    return path

def verify_inputs(manifest):
    if digest(HERE / 'build.config') != manifest['build_config_sha256']:
        raise ValueError('Build configuration checksum mismatch')
    for name, item in manifest['repositories'].items():
        if safe_relative(name).parts != (name,):
            raise ValueError('Invalid repository name')
        src = HERE / 'sources' / name
        if digest(src / 'tracked.patch') != item['patch_sha256']:
            raise ValueError(f'{name}: patch checksum mismatch')
        for entry in item['overlay']:
            path = src / 'overlay' / safe_relative(entry['path'])
            if path.is_symlink() or digest(path) != entry['sha256']:
                raise ValueError(f'{name}: overlay checksum mismatch: {path}')

def restore_repo(name, item, target, reference=None):
    target.parent.mkdir(parents=True, exist_ok=True)
    if reference:
        run('git', '-c', 'core.autocrlf=false', 'clone', '--shared', '--no-checkout',
            str(reference), str(target))
    else:
        run('git', '-c', 'core.autocrlf=false', 'clone', '--filter=blob:none',
            '--no-checkout', item['url'], str(target))
    run('git', 'config', 'core.autocrlf', 'false', cwd=target)
    run('git', 'checkout', '--detach', item['commit'], cwd=target)
    patch = HERE / 'sources' / name / 'tracked.patch'
    if patch.stat().st_size:
        run('git', 'apply', '--check', str(patch), cwd=target)
        run('git', 'apply', str(patch), cwd=target)
    for entry in item['overlay']:
        rel = safe_relative(entry['path'])
        dest = target / rel
        if dest.exists():
            raise ValueError(f'Overlay would overwrite an unexpected existing file: {dest}')
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE / 'sources' / name / 'overlay' / rel, dest)
        dest.chmod(int(entry['mode'], 8))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, nargs='?')
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--reference-tree', type=Path,
                        help='Optional local OpenWrt+feeds object store for offline validation; shared objects must remain available')
    parser.add_argument('--sources-only', action='store_true', help='Skip feed indexing and make defconfig')
    args = parser.parse_args()
    manifest = json.loads((HERE / 'manifest.json').read_text())
    verify_inputs(manifest)
    print('Snapshot hashes verified.', flush=True)
    if args.verify_only:
        return
    if os.name != 'posix':
        parser.error('Prepare/build in Linux, for example WSL2.')
    if args.destination is None:
        parser.error('Specify a new destination directory.')
    dest = args.destination.resolve()
    if dest.exists():
        parser.error('Destination must not exist; no existing checkout is overwritten.')
    ref = args.reference_tree.resolve() if args.reference_tree else None
    for name, item in manifest['repositories'].items():
        target = dest if name == 'openwrt' else dest / 'feeds' / name
        reference = (ref if name == 'openwrt' else ref / 'feeds' / name) if ref else None
        restore_repo(name, item, target, reference)
    shutil.copyfile(HERE / 'build.config', dest / '.config')
    if not args.sources_only:
        run('./scripts/feeds', 'update', '-i', cwd=dest)
        run('./scripts/feeds', 'install', '-a', cwd=dest)
        run('make', 'defconfig', cwd=dest)
        expected = config_values(HERE / 'build.config')
        actual = config_values(dest / '.config')
        changed = {key: [expected.get(key, 'n'), actual.get(key, 'n')]
                   for key in expected.keys() | actual.keys()
                   if expected.get(key, 'n') != actual.get(key, 'n')}
        if changed:
            raise ValueError(f'Configuration changed during defconfig: {changed}')
        print('Effective configuration matches the archived build.', flush=True)
    print(f'Prepared {dest}. Review .config, then run make -j20 V=s there.', flush=True)
    print('No firmware has been built or installed by this script.', flush=True)

if __name__ == '__main__':
    main()
