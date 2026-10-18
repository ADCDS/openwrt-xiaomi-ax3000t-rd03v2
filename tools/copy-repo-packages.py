#!/usr/bin/env python3
"""Copy optional and pinned APKs after dependency builds finish."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[1]
SUPPORT = ('luci-app-nss', 'amneziawg-tools', 'luci-proto-amneziawg',
           'wireguard-tools', 'luci-proto-wireguard', 'luci-app-sqm', 'luci-lib-uqr', 'resolveip')
PREFIX = 'openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2'


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def copy_packages(tree):
    target = tree / 'bin/targets/qualcommax/ipq50xx'
    apk = tree / 'staging_dir/host/bin/apk'
    with tempfile.TemporaryDirectory(prefix='v2-repo-image-') as temporary:
        root = Path(temporary) / 'root.sqfs'
        with tarfile.open(target / (PREFIX + '-squashfs-sysupgrade.bin')) as archive:
            roots = [m for m in archive.getmembers() if m.name.startswith('sysupgrade-') and m.name.endswith('/root')]
            if len(roots) != 1 or not roots[0].isfile():
                raise ValueError('cannot identify actual image package database')
            with archive.extractfile(roots[0]) as source, root.open('wb') as output:
                shutil.copyfileobj(source, output)
        database = subprocess.check_output(['unsquashfs', '-cat', str(root), 'lib/apk/db/installed'], text=True)
    installed, name = {}, None
    for line in database.splitlines():
        if line.startswith('P:'):
            name = line[2:]
        elif line.startswith('V:'):
            if not name:
                raise ValueError('invalid image package database')
            installed[name] = line[2:]
    script = REPO / 'overlay/target/linux/qualcommax/ipq50xx/base-files/etc/uci-defaults/95-rd03v2-apk-pins'
    pins = re.search(r"^PINS='([^']+)'", script.read_text(), re.M).group(1).split()
    copied = []
    for package in dict.fromkeys((*SUPPORT, *pins)):
        expected = installed.get(package)
        if package in pins and not expected:
            raise ValueError('pinned package absent from actual image: ' + package)
        pattern = package + '-' + (expected if expected else '[0-9]*') + '.apk'
        sources = list((tree / 'bin/packages').glob('*/*/' + pattern))
        if not sources:
            sources = list((target / 'packages').glob(pattern))
        if len(sources) != 1:
            raise ValueError('expected one exact APK for ' + package + ', found ' + str(len(sources)))
        source = sources[0]
        info = json.loads(subprocess.check_output([str(apk), 'adbdump', '--format', 'json', str(source)]))['info']
        if info['name'] != package or (expected and info['version'] != expected):
            raise ValueError('APK identity differs from actual image: ' + package)
        destination = target / 'packages' / source.name
        for stale in (target / 'packages').glob(package + '-[0-9]*.apk'):
            if stale != destination:
                stale.unlink()
        if not destination.exists() or sha(destination) != sha(source):
            shutil.copy2(source, destination)
        copied.append({'name': package, 'version': info['version'], 'sha256': sha(destination)})
    # copy2 preserves timestamps. An APK rebuilt under the same version may
    # otherwise look older than index.json and escape make's freshness check.
    for filename in ('packages.adb', 'index.json'):
        (target / 'packages' / filename).unlink(missing_ok=True)
    return copied


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tree', type=Path)
    args = parser.parse_args()
    print(json.dumps({'packages': copy_packages(args.tree.resolve())}, indent=2))


if __name__ == '__main__':
    main()
