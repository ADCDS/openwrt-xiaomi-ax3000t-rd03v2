#!/usr/bin/env bash
# initramfs-extract.sh — pull a file (or the whole cpio) out of a *built*
# initramfs artifact, so a release check can look at what actually shipped
# instead of trusting a filename.
#
# WHY THIS EXISTS
#   v1.7 ships two initramfs flavours per build tree that differ ONLY in the
#   contents of /etc/rc.local (tools/installer-wifi.rc.local). The failure mode
#   to guard against is a second image pass that silently produced a byte-
#   identical image — or worse, a *default* image that picked the beaconing
#   rc.local up. Comparing hashes catches the first; only reading the file out
#   of the image catches the second. tools/wifi-initramfs.sh and
#   tools/mkrelease.sh both gate on this.
#
#   Usage:
#     ./tools/initramfs-extract.sh IMAGE etc/rc.local     # print one file
#     ./tools/initramfs-extract.sh IMAGE --list           # list the cpio
#     ./tools/initramfs-extract.sh IMAGE --cpio > out.cpio
#
#   IMAGE may be a FIT uImage (…-initramfs-uImage.itb) or the UBI wrapper
#   (…-initramfs-factory.ubi); both carry the same kernel and the same embedded
#   initramfs.
#
# HOW
#   Nothing here hardcodes the container layout, because it has already changed
#   once upstream: today the .itb is a FIT whose kernel node is gzip, and the
#   kernel's embedded initramfs is zstd, but that is a kconfig default and not a
#   promise. So: strip UBI framing if present, then recursively carve every
#   recognised compressed stream and keep whichever one decompresses to a newc
#   cpio archive. If none does, this exits non-zero — it never returns "nothing
#   found" as success, because callers use a *negative* result as evidence.
#
# Needs python3 (the OpenWrt build system requires it anyway) plus zstd/xz/lz4
# only if the image happens to use them.
set -euo pipefail

usage() {
	echo "usage: $0 IMAGE (--list | --cpio | PATH-IN-INITRAMFS)" >&2
	exit 2
}

[ $# -eq 2 ] || usage
IMG=$1; WHAT=$2
[ -f "$IMG" ] || { echo "ERROR: no such image: $IMG" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 2; }

exec python3 - "$IMG" "$WHAT" <<'PYEOF'
import bz2, collections, lzma, os, struct, subprocess, sys, zlib

# NB: do NOT restore SIGPIPE to SIG_DFL process-wide to make `--list | head`
# quiet. _pipe() below feeds a whole image to zstd/lz4/lzop, and a probe that
# hits a false-positive magic makes the child exit while we are still writing —
# with SIG_DFL that kills *this* process, and the caller sees the extraction
# "fail" on a perfectly good image. Python's default (BrokenPipeError) is what
# lets those probes be non-fatal; the writes we own are guarded at the end.
img, what = sys.argv[1], sys.argv[2]
raw = open(img, 'rb').read()

CPIO_MAGIC = b'070701'


def looks_like_cpio(b):
    # A newc archive starts with a header and holds one per file. Requiring both
    # keeps a lucky carve of some other blob from being accepted as the rootfs.
    return b[:6] == CPIO_MAGIC and b.count(CPIO_MAGIC) > 20


# ---------------------------------------------------------------- UBI framing
def ubi_volumes(b):
    """Yield the payload of each volume in a UBI image, largest volume first.

    Every PEB is EC header ("UBI#") + VID header ("UBI!") + data; the headers
    sit *inside* the volume's byte stream and would corrupt any compressed
    stream carved straight out of the file.
    """
    starts = []
    off = b.find(b'UBI#')
    while off != -1:
        starts.append(off)
        off = b.find(b'UBI#', off + 4)
    if len(starts) < 2:
        return
    deltas = collections.Counter(b - a for a, b in zip(starts, starts[1:]))
    peb = deltas.most_common(1)[0][0]
    vols = collections.defaultdict(dict)
    for s in starts:
        if b[s:s + 4] != b'UBI#':
            continue
        vid_off, data_off = struct.unpack('>II', b[s + 16:s + 24])
        v = s + vid_off
        if b[v:v + 4] != b'UBI!':
            continue                      # free/erased PEB
        vol_id, lnum = struct.unpack('>II', b[v + 8:v + 16])
        data_size, = struct.unpack('>I', b[v + 20:v + 24])
        payload = b[s + data_off:s + peb]
        if data_size:                     # static volume: exact length
            payload = payload[:data_size]
        vols[vol_id][lnum] = payload
    out = []
    for vol_id, lebs in vols.items():
        out.append(b''.join(lebs[i] for i in sorted(lebs)))
    out.sort(key=len, reverse=True)
    return out


# ------------------------------------------------------- compressed stream(s)
def _pipe(tool, data):
    # Nonzero exit and a half-consumed stdin are both expected here: we hand the
    # tool everything from the magic to EOF, so there is almost always trailing
    # data after the stream it decodes. Keep whatever it managed to write.
    try:
        p = subprocess.run(tool, input=data, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL)
    except (FileNotFoundError, BrokenPipeError):
        return b''
    return p.stdout


def _gzip(d):
    return zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(d)


def _xz(d):
    return lzma.LZMADecompressor(format=lzma.FORMAT_XZ).decompress(d)


def _lzma(d):
    return lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(d)


DECOMP = [
    (b'\x1f\x8b\x08',                     _gzip),
    (b'\x28\xb5\x2f\xfd',                 lambda d: _pipe(['zstd', '-dc'], d)),
    (b'\xfd7zXZ\x00',                     _xz),
    (b'BZh',                              lambda d: bz2.BZ2Decompressor().decompress(d)),
    (b'\x02\x21\x4c\x18',                 lambda d: _pipe(['lz4', '-dc', '-l'], d)),
    (b'\x04\x22\x4d\x18',                 lambda d: _pipe(['lz4', '-dc'], d)),
    (b'\x89LZO\x00\r\n\x1a\n',            lambda d: _pipe(['lzop', '-dc'], d)),
    # lzma-alone has no magic; 0x5d is the props byte the kernel/OpenWrt emit.
    (b'\x5d\x00\x00',                     _lzma),
]

MAX_DEPTH = 4
MIN_USEFUL = 4096


def find_cpio(b, depth=0):
    if looks_like_cpio(b):
        return b
    if depth >= MAX_DEPTH:
        return None
    for magic, fn in DECOMP:
        off = b.find(magic)
        while off != -1:
            try:
                out = fn(b[off:])
            except Exception:
                out = b''
            if len(out) >= MIN_USEFUL:
                got = find_cpio(out, depth + 1)
                if got is not None:
                    return got
            off = b.find(magic, off + 1)
    return None


cpio = None
if raw[:4] == b'UBI#':
    for vol in (ubi_volumes(raw) or []):
        cpio = find_cpio(vol)
        if cpio is not None:
            break
if cpio is None:
    cpio = find_cpio(raw)

if cpio is None:
    sys.exit("ERROR: no initramfs cpio found inside %s — refusing to report "
             "'absent' from a failed extraction" % img)


# ------------------------------------------------------------- newc cpio read
def cpio_entries(b):
    p = 0
    while p + 110 <= len(b):
        if b[p:p + 6] != CPIO_MAGIC:
            break
        f = [int(b[p + 6 + i * 8:p + 14 + i * 8], 16) for i in range(13)]
        mode, filesize, namesize = f[1], f[6], f[11]
        name = b[p + 110:p + 110 + namesize - 1].decode('utf-8', 'replace')
        dp = (p + 110 + namesize + 3) & ~3
        data = b[dp:dp + filesize]
        if name == 'TRAILER!!!':
            break
        yield name, mode, data
        p = (dp + filesize + 3) & ~3


try:
    if what == '--cpio':
        sys.stdout.buffer.write(cpio)
    elif what == '--list':
        for name, mode, data in cpio_entries(cpio):
            print('%06o %8d %s' % (mode, len(data), name))
    else:
        want = what.lstrip('./')
        for name, mode, data in cpio_entries(cpio):
            if name.lstrip('./') == want:
                sys.stdout.buffer.write(data)
                break
        else:
            sys.exit("ERROR: %s not present in the initramfs of %s" % (what, img))
    sys.stdout.buffer.flush()
except BrokenPipeError:
    # `... --list | head`. Drop the fd so the interpreter's own flush at exit
    # cannot re-raise, and report success: the output we were asked for was
    # produced, the reader simply stopped reading.
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    sys.exit(0)
PYEOF
