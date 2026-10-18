#!/usr/bin/env python3
"""Exercise real signed APK fixtures, including correctly signed bad indexes."""
import contextlib
import importlib.util
import io
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

repo = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verifier', repo / 'tools/verify-artifacts.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
tree = Path(sys.argv[1]).resolve()
packages = tree / 'bin/targets/qualcommax/ipq50xx/packages'
apk = tree / 'staging_dir/host/bin/apk'
keys = repo / 'keys'
private_key = repo.parent / 'keys/v2/private-key.pem'


def check(directory, kernel=None):
    with contextlib.redirect_stdout(io.StringIO()):
        return verifier.verify_packages(directory, apk, keys, kernel)


def rejected(label, operation):
    try:
        operation()
    except (ValueError, OSError, subprocess.CalledProcessError):
        print('PASS rejected ' + label)
    else:
        raise AssertionError('accepted ' + label)


def payload_variants(data):
    """Repack unchanged and corrupt one file byte, preserving metadata/signature.

    ADBd uses raw deflate. Its final bits may terminate the compression stream
    after all authenticated file bytes; changing those does not corrupt a file.
    ADB block sizes include their headers and align to eight bytes (APK3 adb.h).
    """
    if data[:4] != b'ADBd':
        raise ValueError('negative fixture requires an ADBd package')
    raw = zlib.decompress(data[4:], -15)
    if raw[:8] != b'ADB.pckg':
        raise ValueError('negative fixture is not an ADB package')
    position, candidates = 8, []
    while position < len(raw):
        word = struct.unpack_from('<I', raw, position)[0]
        kind, size, header = word >> 30, word & 0x3fffffff, 4
        if kind == 3:
            kind, size, header = word & 0x3fffffff, struct.unpack_from('<Q', raw, position + 8)[0], 16
        if size < header or position + size > len(raw):
            raise ValueError('invalid ADB block in negative fixture')
        # Data blocks begin with two 32-bit directory/file indexes, then bytes.
        if kind == 2 and size > header + 8:
            candidates.append((size - header - 8, position + header + 8))
        position += (size + 7) & ~7
    if position != len(raw) or not candidates:
        raise ValueError('negative fixture has no complete file-data block')
    modified = bytearray(raw)
    _, offset = max(candidates)
    modified[offset] ^= 1

    def repack(body):
        compressor = zlib.compressobj(wbits=-15)
        return b'ADBd' + compressor.compress(body) + compressor.flush()

    return repack(raw), repack(modified)


kernel = check(packages)
print('PASS complete signed repository')
rejected('different kernel vermagic', lambda: check(packages, kernel + '.wrong'))
with tempfile.TemporaryDirectory(prefix='v2-package-negatives-') as temporary:
    work = Path(temporary)
    fixture = work / 'repo'
    shutil.copytree(packages, fixture)
    all_apks = sorted(fixture.glob('*.apk'))
    original_index = (fixture / 'packages.adb').read_bytes()
    subprocess.run([str(apk), 'mkndx', '--keys-dir', str(keys), '--sign-key',
                    str(private_key), '--output', str(fixture / 'packages.adb'),
                    *map(str, all_apks[:-1])], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rejected('correctly signed incomplete index', lambda: check(fixture))
    (fixture / 'packages.adb').write_bytes(original_index)
    chosen = all_apks[-1]
    wrong_name = fixture / ('wrong-' + chosen.name)
    chosen.rename(wrong_name)
    rejected('valid APK with the wrong filename', lambda: check(fixture))
    wrong_name.rename(chosen)
    saved = chosen.read_bytes()
    chosen.unlink()
    rejected('missing indexed APK', lambda: check(fixture))
    chosen.write_bytes(saved)
    unchanged, corrupted = payload_variants(saved)
    chosen.write_bytes(unchanged)
    subprocess.run([str(apk), 'verify', '--keys-dir', str(keys), str(chosen)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print('PASS repacked unchanged authenticated payload')
    chosen.write_bytes(corrupted)
    # Verify the single APK: repacking changes encoded file_size in the index,
    # which must not be the reason this payload-corruption check rejects it.
    rejected('corrupted authenticated file bytes', lambda: subprocess.run(
        [str(apk), 'verify', '--keys-dir', str(keys), str(chosen)], check=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    chosen.write_bytes(saved)
    unrelated = work / 'unrelated-keys'
    unrelated.mkdir()
    subprocess.run(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout',
                    '-out', str(work / 'unrelated-private.pem')], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['openssl', 'ec', '-in', str(work / 'unrelated-private.pem'), '-pubout',
                    '-out', str(unrelated / 'public-key.pem')], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rejected('untrusted signing key', lambda: verifier.verify_packages(fixture, apk, unrelated))
print('8 passed, 0 failed')
