#!/usr/bin/env python3
"""Independent checks of assembled, locally served, and installed v2 artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request

REPO = Path(__file__).resolve().parents[2]
PREFIX = 'openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2'
BOARD = 'xiaomi,mi-router-ax3000t-v2'


def run(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs).stdout


def sha(path):
    with open(path, 'rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def require(condition, label):
    if not condition:
        raise ValueError(label)
    print('PASS ' + label)


def stamp(text):
    result = {}
    for line in text.splitlines():
        if not re.match(r'^RD03V2_[A-Z_]+=', line):
            continue
        key, value = line.split('=', 1)
        fields = shlex.split(value)
        if len(fields) != 1:
            raise ValueError('invalid release stamp')
        result[key] = fields[0]
    return result


def manifest(db):
    name = None
    entries = {}
    for line in db.splitlines():
        if line.startswith('P:'):
            name = line[2:]
        elif line.startswith('V:') and name:
            entries[name] = line[2:]
    return entries


def unpack_root(image, destination):
    # Read only the root member; never extract arbitrary archive paths.
    with tarfile.open(image) as archive:
        roots = [m for m in archive.getmembers()
                 if m.name.startswith('sysupgrade-') and m.name.endswith('/root')]
        if len(roots) != 1 or not roots[0].isfile():
            raise ValueError('sysupgrade must contain one root squashfs')
        squashfs = destination / 'root.sqfs'
        with archive.extractfile(roots[0]) as source, squashfs.open('wb') as target:
            import shutil
            shutil.copyfileobj(source, target)
    root = destination / 'root'
    subprocess.run(['unsquashfs', '-q', '-d', str(root), str(squashfs)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    require((root / 'lib/apk/db/installed').is_file(), 'sysupgrade root extracted')
    return root


def verify_packages(directory, apk, keys, expected_kernel=None):
    packages = sorted(directory.glob('*.apk'))
    require(bool(packages), 'package set is nonempty')
    index = directory / 'packages.adb'
    run([apk, 'verify', '--keys-dir', keys, index, *packages])
    require(True, 'index and all packages verify with the committed key')
    observed = json.loads(run([apk, 'adbdump', '--format', 'json', index]))['packages']
    with tempfile.TemporaryDirectory(prefix='v2-index-') as temporary:
        generated = Path(temporary) / 'packages.adb'
        run([apk, 'mkndx', '--keys-dir', keys, '--output', generated, *packages])
        expected = json.loads(run([apk, 'adbdump', '--format', 'json', generated]))['packages']
    key = lambda entry: (entry['name'], entry['version'])
    require(sorted(observed, key=key) == sorted(expected, key=key),
            'signed index metadata and identities match every supplied APK')
    infos = {p: json.loads(run([apk, 'adbdump', '--format', 'json', p]))['info']
             for p in packages}
    identities = [(info['name'], info['version']) for info in infos.values()]
    require(len(set(identities)) == len(identities), 'package identities are unique')
    for package, info in infos.items():
        require(package.name == info['name'] + '-' + info['version'] + '.apk',
                'package filename matches metadata: ' + package.name)
    kernels = [p for p in packages if infos[p]['name'] == 'kernel']
    require(len(kernels) == 1, 'exactly one kernel package')
    kernel = infos[kernels[0]]['version']
    if expected_kernel:
        require(kernel == expected_kernel, 'repository kernel matches the flashed image')
    count = 0
    for package in packages:
        if not infos[package]['name'].startswith('kmod-'):
            continue
        deps = [dep.removeprefix('kernel=') for dep in infos[package].get('depends', [])
                if dep.startswith('kernel=')]
        require(deps == [kernel], 'kernel dependency: ' + package.name)
        count += 1
    require(count > 0, 'kernel module dependencies checked')
    return kernel


def initramfs_file(image, name):
    return run([REPO / 'v2/tools/initramfs-extract.sh', image, name]).decode()


def verify_release(directory, apk, keys):
    sums_path = directory / 'sha256sums.txt'
    sums = {}
    for line in sums_path.read_text().splitlines():
        fields = line.split()
        if len(fields) != 2 or not re.fullmatch('[0-9a-f]{64}', fields[0]):
            raise ValueError('invalid checksum line')
        name = fields[1].lstrip('*')
        if Path(name).name != name or name in sums:
            raise ValueError('unsafe or duplicate checksum name')
        sums[name] = fields[0]
    actual = {p.name for p in directory.iterdir() if p.is_file() and p.name != 'sha256sums.txt'}
    require(actual == set(sums), 'checksums cover every artifact exactly')
    for name, digest in sums.items():
        require(sha(directory / name) == digest, 'checksum: ' + name)
    with tempfile.TemporaryDirectory(prefix='v2-release-') as temporary:
        work = Path(temporary)
        root = unpack_root(directory / (PREFIX + '-squashfs-sysupgrade.bin'), work)
        identity = stamp((root / 'etc/rd03v2-release').read_text())
        installed = manifest((root / 'lib/apk/db/installed').read_text())
        lock = (REPO / 'v2/upstream.lock').read_text()
        revision = re.search(r'^COMMIT=(\S+)', lock, re.M).group(1)
        base_release = re.search(r'^RELEASE=(\S+)', lock, re.M).group(1)
        require(identity['RD03V2_BASE'] == f'kuncy7/openwrt-nss-edma {base_release} {revision}',
                'release provenance matches the pinned upstream')
        for entry in (REPO / 'v2/config/image-must-have.txt').read_text().splitlines():
            entry = entry.strip()
            if not entry or entry.startswith('#'):
                continue
            absent, name = entry.startswith('!'), entry.lstrip('!')
            require((name in installed) != absent, 'image package policy: ' + entry)
        recorded = '\n'.join(f'{n} - {v}' for n, v in sorted(installed.items())) + '\n'
        require((directory / (PREFIX + '.manifest')).read_text() == recorded,
                'release manifest is the actual image package set')
        distfeeds = [identity['RD03V2_REPO']] + [
            f'https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/{feed}/packages.adb'
            for feed in ('base', 'luci', 'packages', 'routing', 'telephony', 'video')]
        require((root / 'etc/apk/repositories.d/distfeeds.list').read_text().splitlines()
                == distfeeds, 'complete repository list agrees with release policy')
        require(os.access(root / 'usr/sbin/nfc', os.X_OK) and
                os.access(root / 'usr/sbin/i2ctransfer', os.X_OK) and
                (root / 'etc/rc.d/S99nfc').is_symlink(), 'NFC tools and service present')
        require((root / 'usr/sbin/nfc').read_bytes() ==
                (REPO / 'v2/overlay/target/linux/qualcommax/ipq50xx/base-files/usr/sbin/nfc').read_bytes(),
                'NFC tool matches the reviewed source including private transfer errors')
        keep = root / 'lib/upgrade/keep.d/rd03v2-watchdog'
        require(keep.is_file() and keep.read_text().splitlines() == ['/etc/rd03v2-watchdog.disable'],
                'sysupgrade preserves the watchdog file opt-out')
        trusted = list((root / 'etc/apk/keys').glob('*'))
        require(any(p.read_bytes() == (keys / 'public-key.pem').read_bytes()
                    for p in trusted if p.is_file()), 'image trusts the committed signing key')
        fwtool = apk.parent / 'fwtool'
        metadata = work / 'fwtool.json'
        run([fwtool, '-i', metadata, directory / (PREFIX + '-squashfs-sysupgrade.bin')])
        require(BOARD in json.loads(metadata.read_text())['supported_devices'],
                'sysupgrade metadata supports RD03v2')
        archives = list(directory.glob(PREFIX + '-packages-*.tar.gz'))
        require(len(archives) == 1, 'exactly one package archive')
        package_root = work / 'packages'
        package_root.mkdir()
        with tarfile.open(archives[0]) as archive:
            for member in archive.getmembers():
                if not member.isfile() and not member.isdir():
                    raise ValueError('package archive contains links or special files')
            archive.extractall(package_root, filter='data')
        indexes = list(package_root.glob('*/packages.adb'))
        require(len(indexes) == 1, 'one archived package index')
        verify_packages(indexes[0].parent, apk, keys, installed['kernel'])
        available = {json.loads(run([apk, 'adbdump', '--format', 'json', p]))['info']['name']
                     for p in indexes[0].parent.glob('*.apk')}
        require({'kmod-wireguard', 'kmod-amneziawg', 'amneziawg-tools',
                 'luci-proto-amneziawg', 'luci-app-nss', 'wireguard-tools',
                 'luci-proto-wireguard', 'luci-app-sqm', 'luci-lib-uqr', 'resolveip'} <= available,
                'WireGuard, AmneziaWG and NSS LuCI packages available')
        pin_script = root / 'etc/uci-defaults/95-rd03v2-apk-pins'
        pins = re.search(r"^PINS='([^']+)'", pin_script.read_text(), re.M).group(1).split()
        for name in pins:
            require((indexes[0].parent / f'{name}-{installed[name]}.apk').is_file(),
                    'pinned package available: ' + name)
        for wifi in (False, True):
            suffix = '-wifi' if wifi else ''
            ubi = directory / (PREFIX + '-initramfs-factory' + suffix + '.ubi')
            itb = directory / (PREFIX + '-initramfs-uImage' + suffix + '.itb')
            require(ubi.is_file() and itb.is_file(), 'UBI/ITB pair: ' + (suffix or 'cable'))
            # Reuse the installer's byte-exact UBI/FIT comparison implementation.
            import sys
            sys.path.insert(0, str(REPO.parent / 'xiaomi-openwrt-install'))
            import install
            try:
                install.expected_volume(str(ubi), str(itb))
            except install.Abort as error:
                raise ValueError(str(error)) from error
            require(True, 'UBI and ITB bytes match: ' + (suffix or 'cable'))
            default = run(['fdtget', '-t', 's', itb, '/configurations', 'default']).decode().strip()
            require(default == 'config@mp03.3',
                    'installer FIT defaults to this board')
            node = run(['fdtget', '-t', 's', itb, '/configurations/' + default, 'fdt']).decode().strip()
            require(bool(node) and Path(node).name == node and '\\' not in node,
                    'installer FIT references one embedded board DTB')
            dtb = work / ('wifi.dtb' if wifi else 'cable.dtb')
            values = run(['fdtget', '-t', 'bx', itb, '/images/' + node, 'data']).decode().split()
            dtb.write_bytes(bytes(int(value, 16) for value in values))
            require(dtb.read_bytes().startswith(bytes.fromhex('d00dfeed')),
                    'installer board DTB has the FDT header')
            for prop, expected in [('status', 'okay'), ('clock-frequency', '100000'),
                                   ('dma-names', 'tx rx')]:
                kind = 'u' if prop == 'clock-frequency' else 's'
                value = run(['fdtget', '-t', kind, dtb, '/soc@0/i2c@78b7000', prop]).decode().strip()
                require(value == expected, 'installer NFC DTB: ' + prop)
            # mkrelease copies whatever installer pair the tree holds, and the Wi-Fi pair is
            # made by a separate step (wifi-initramfs-v2.sh): an earlier build shipped an older pair.
            require(stamp(initramfs_file(itb, 'etc/rd03v2-release')) == identity,
                    'installer was built for this release: ' + (suffix or 'cable'))
            rc = initramfs_file(itb, 'etc/rc.local')
            require(('OpenWrt-RD03v2-Installer' in rc) == wifi,
                    'beacon belongs only to the Wi-Fi installer')
            early = initramfs_file(itb, 'etc/init.d/rd03v2-installer')
            require('START=17' in early and 'tmpfs' in early and
                    "nss.general.enabled='0'" in early,
                    'RAM installer disables NSS before bring-up')
            if wifi:
                require('tmpfs' in rc, 'installer beacon is gated on RAM rootfs')
        require(sha(directory / (PREFIX + '-initramfs-uImage.itb')) !=
                sha(directory / (PREFIX + '-initramfs-uImage-wifi.itb')),
                'Wi-Fi installer is distinct')
        nand = (directory / 'nand-support.txt').read_text()
        require(bool(re.search(r'^11\s+c8:11\s', nand, re.M)) and
                bool(re.search(r'^be\s+ef:be\s', nand, re.M)), 'both NAND parts supported')
        require(not (root / 'dev/mem').exists(), 'permanent image has no devmem node')
        statistics = (root / 'etc/init.d/qca-nss-pbuf').read_text()
        require('xiaomi,mi-router-ax3000t-v2' in statistics and
                'stats_disable_default=0' in statistics and
                'config_get stats_disable opt stats_disable "$stats_disable_default"' in statistics,
                'RD03v2 basic statistics default preserves explicit override')
        run(['python3', REPO / 'v2/tools/test-pbuf-policy.py',
             root / 'etc/init.d/qca-nss-pbuf'])
        modules = list((root / 'lib/modules').glob('*/ath11k.ko'))
        require(len(modules) == 1 and
                b'rd03v2_rx_diag_samples' not in modules[0].read_bytes() and
                b'rd03v2-mon' not in modules[0].read_bytes(),
                'permanent module excludes temporary receive diagnostics')
        # Diagnostic builds of an earlier round carried private user-PD experiments
        # (never part of v2); their trace lines mark such a build.
        ahb = list((root / 'lib/modules').glob('*/ath11k_ahb.ko'))
        require(len(ahb) == 1 and b'rd03v2 userpd trace' not in ahb[0].read_bytes(),
                'permanent module excludes the private user-PD experiments')
        require('OpenWrt-RD03v2-Installer' not in (root / 'etc/rc.local').read_text(),
                'permanent image has no installer beacon')
        return identity, installed, sums


def verify_served(directory, base_url, apk, keys):
    identity, installed, sums = verify_release(directory, apk, keys)
    base = base_url.rstrip('/') + '/releases/' + identity['RD03V2_TAG'] + '/'
    for name, digest in sums.items():
        with urllib.request.urlopen(base + urllib.parse.quote(name), timeout=30) as response:
            require(hashlib.file_digest(response, 'sha256').hexdigest() == digest,
                    'local served artifact: ' + name)
    with tempfile.TemporaryDirectory(prefix='v2-served-') as temporary:
        packages = Path(temporary)
        repo_url = identity['RD03V2_REPO']
        require(urllib.parse.urlparse(repo_url).netloc == urllib.parse.urlparse(base_url).netloc,
                'repository and artifacts use the expected local server')
        with urllib.request.urlopen(repo_url, timeout=30) as response:
            (packages / 'packages.adb').write_bytes(response.read())
        index = json.loads(run([apk, 'adbdump', '--format', 'json', packages / 'packages.adb']))
        entries = [(entry['name'], entry['version']) for entry in index['packages']]
        require(bool(entries), 'served package index has entries')
        for name, version in entries:
            filename = name + '-' + version + '.apk'
            require(Path(filename).name == filename and '/' not in filename and '\\' not in filename,
                    'safe served package filename: ' + filename)
            with urllib.request.urlopen(urllib.parse.urljoin(repo_url, filename), timeout=30) as response:
                (packages / filename).write_bytes(response.read())
        verify_packages(packages, apk, keys, installed['kernel'])
        archives = list(directory.glob(PREFIX + '-packages-*.tar.gz'))
        with tarfile.open(archives[0]) as archive:
            expected = {Path(m.name).name: hashlib.sha256(archive.extractfile(m).read()).hexdigest()
                        for m in archive.getmembers() if m.isfile() and Path(m.name).name != 'index.json'}
        # OpenWrt's index.json is a build cache; clients use the signed packages.adb.
        require(set(expected) == {p.name for p in packages.iterdir()},
                'served repository has every released APK and its signed index')
        require(all(sha(packages / name) == digest for name, digest in expected.items()),
                'served package bytes and index match the release archive')
    print('INFO local served fixture verified; no publication performed')


def verify_device(directory, ssh_command, apk, keys):
    identity, installed, _ = verify_release(directory, apk, keys)
    prefix = shlex.split(ssh_command)
    board = json.loads(run(prefix + ['ubus call system board']).decode())
    require(board.get('board_name') == BOARD, 'bench identity')
    require(board.get('rootfs_type') == 'squashfs', 'bench runs permanent image')
    require(board.get('kernel') == installed['kernel'].split('~')[0], 'running kernel version')
    observed = stamp(run(prefix + ['cat /etc/rd03v2-release']).decode())
    require(observed == identity, 'installed release stamp')
    world = run(prefix + ['cat /etc/apk/world']).decode().splitlines()
    actual_installed = manifest(run(prefix + ['cat /lib/apk/db/installed']).decode())
    require(actual_installed.get('kernel') == installed['kernel'], 'installed kernel vermagic')
    config = REPO / 'v2/overlay/target/linux/qualcommax/ipq50xx/base-files/etc/uci-defaults/95-rd03v2-apk-pins'
    pins = re.search(r"^PINS='([^']+)'", config.read_text(), re.M).group(1).split()
    for name in pins:
        require(f'{name}={installed[name]}' in world, 'installed pin: ' + name)
        require(actual_installed.get(name) == installed[name], 'installed pinned version: ' + name)
    require(run(prefix + ['head -1 /etc/apk/repositories.d/distfeeds.list']).decode().strip()
            == identity['RD03V2_REPO'], 'installed package repository')
    hashes = run(prefix + ['sha256sum /etc/apk/keys/*']).decode()
    require(sha(keys / 'public-key.pem') in hashes, 'installed trusted key')
    require(run(prefix + ['test ! -e /dev/mem && echo absent']).decode().strip() == 'absent',
            'running system lacks devmem')
    require(run(prefix + ['uci -q get rd03v2.v2.migrated']).decode().strip() == '1',
            'migration marker present')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['release', 'published', 'device', 'packages'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--apk', type=Path, default=Path(os.environ.get('V2_APK',
                        REPO / 'openwrt-v2/staging_dir/host/bin/apk')))
    parser.add_argument('--keys', type=Path, default=REPO / 'v2/keys')
    parser.add_argument('--base-url')
    parser.add_argument('--ssh-command')
    import sys
    argv = sys.argv[1:]
    if not argv:
        parser.print_help()
        return 2
    mode = argv.pop(0)
    args = parser.parse_args([mode.removeprefix('--'), *argv])
    try:
        directory = args.directory.resolve()
        apk, keys = args.apk.resolve(), args.keys.resolve()
        if args.mode == 'release':
            verify_release(directory, apk, keys)
        elif args.mode == 'packages':
            verify_packages(directory, apk, keys)
        elif args.mode == 'published':
            if not args.base_url:
                parser.error('--published requires --base-url')
            verify_served(directory, args.base_url, apk, keys)
        else:
            if not args.ssh_command:
                parser.error('--device requires --ssh-command')
            verify_device(directory, args.ssh_command, apk, keys)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('FAIL', str(error))
        return 1
    print('verify-v2: 0 failure(s)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
