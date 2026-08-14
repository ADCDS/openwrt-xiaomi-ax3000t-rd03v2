#!/usr/bin/env bash
# mknand-support.sh — emit nand-support.txt for a release, derived from the
# kernel that was actually built.
#
# WHY THIS EXISTS
#   The RD03v2's SPI-NAND is second-sourced. Most units carry an ESMT
#   F50D1G41LB; some carry a Winbond W25N01KWZEIG, which no release before v1.7
#   could probe at all (empty /proc/mtd, UBI cannot attach, no radios). An
#   installer therefore has to know, *before* it writes anything, whether the
#   release it is about to flash can drive the chip in front of it. Hardcoding a
#   table in the installer means the installer goes stale the moment a release
#   adds a part; shipping the answer as a release asset means the release
#   describes itself.
#
#   A unit self-identifies through the stock bootloader: it probes the chip with
#   its own serial-NAND ID table and leaves the device byte in the U-Boot
#   environment as `flash_type`, readable from a running system with
#   `fw_printenv flash_type` (or `nvram get flash_type` on stock). That byte is
#   the join key, so it is what this file is keyed on.
#
# WHERE THE TWO HALVES COME FROM
#   * kernel side: parsed out of drivers/mtd/nand/spi/*.c in the tree that was
#     built, restricted to the vendor objects that tree's Makefile actually
#     compiles. Not a guess and not a copy — mainline builds every vendor table
#     into one driver, so the answer is much larger than "ESMT and Winbond", and
#     it moves whenever the pinned OpenWrt commit moves.
#   * bootloader side: the table below, decoded from a dump of 0:APPSBL taken
#     off a real unit. A part the bootloader cannot identify cannot be this
#     board's boot NAND however well the kernel knows it, so those parts are
#     emitted without a flash_type.
#
#   Usage:  ./tools/mknand-support.sh /path/to/openwrt > nand-support.txt
set -euo pipefail

TREE="${1:-${TREE:-}}"
[ -n "$TREE" ] || { echo "usage: $0 /path/to/openwrt > nand-support.txt" >&2; exit 2; }
TREE="$(cd "$TREE" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

SPI=$(echo "$TREE"/build_dir/target-*/linux-*/linux-*/drivers/mtd/nand/spi)
[ -d "$SPI" ] || die "no drivers/mtd/nand/spi in $TREE — is the kernel unpacked/built?"
KCONF=$(echo "$TREE"/build_dir/target-*/linux-*/linux-*/.config)
[ -f "$KCONF" ] || die "no kernel .config under $TREE/build_dir"
grep -q '^CONFIG_MTD_SPI_NAND=[ym]$' "$KCONF" \
	|| die "CONFIG_MTD_SPI_NAND is not enabled in $KCONF — this build has no SPI-NAND at all"

KVER=$(basename "$(dirname "$(dirname "$SPI")")")

exec python3 - "$SPI" "$KVER" "$TREE" <<'PY'
import os, re, sys

spi, kver, tree = sys.argv[1], sys.argv[2], sys.argv[3]

# ---- the stock bootloader's serial-NAND ID table (decoded from 0:APPSBL) ----
# (manufacturer byte, device byte) -> bootloader's own name for the part.
BOOTLOADER = {
    (0xc8, 0x11): "ESMT F50D1G41LB",
    (0xef, 0xbe): "Winbond W25N01KWZEIG",
    (0xef, 0xba): "Winbond W25N01GWZEIG",
    (0xef, 0xbc): "Winbond W25N01JW",
    (0xef, 0xbf): "Winbond W25N02JWZEIF",
    (0xc8, 0xc9): "GigaDevice GD5F1GQ4RE9IH",
    (0xc8, 0x22): "GigaDevice GD5F2GQ5REYIH",
    (0xc8, 0x41): "GigaDevice GD5F1GQ5REYIG",
    (0xc8, 0x21): "GigaDevice GD5F1GQ5REYIH",
    (0xc8, 0x81): "GigaDevice GD5F1GM7REYIG",
    (0xc2, 0x92): "Macronix MX35UF1GE4AC",
    (0x2c, 0x15): "Micron MT29F1G01ABBFDWB",
}

# ---- which vendor tables this kernel actually compiles ----------------------
mk = open(os.path.join(spi, 'Makefile')).read()
objs = set(re.findall(r'([a-z0-9_]+)\.o', mk)) - {'spinand', 'core'}
built = sorted(o for o in objs if os.path.exists(os.path.join(spi, o + '.c')))
if not built:
    sys.exit("ERROR: could not work out which vendor tables are built from %s" % spi)

# ---- SPINAND_MFR_* -> byte -------------------------------------------------
mfr_byte = {}
hdrs = [os.path.join(spi, 'core.c')]
for root, _, files in os.walk(os.path.join(tree, 'build_dir')):
    if root.endswith(os.path.join('include', 'linux', 'mtd')) and 'spinand.h' in files:
        hdrs.append(os.path.join(root, 'spinand.h'))
        break
for h in hdrs:
    try:
        txt = open(h).read()
    except OSError:
        continue
    for name, val in re.findall(r'#define\s+(SPINAND_MFR_[A-Z0-9_]+)\s+(0x[0-9a-fA-F]+)', txt):
        mfr_byte[name] = int(val, 16)

# ---- parse each vendor file ------------------------------------------------
parts = []            # (mfr_byte, dev_byte, part_name, vendor_label)
for obj in built:
    src = open(os.path.join(spi, obj + '.c')).read()
    m = re.search(r'\.id\s*=\s*(SPINAND_MFR_[A-Z0-9_]+)', src)
    if not m:
        continue
    mb = mfr_byte.get(m.group(1))
    if mb is None:
        continue
    vm = re.search(r'\.name\s*=\s*"([^"]+)"', src[m.start():m.start() + 400])
    vendor = vm.group(1) if vm else obj
    for pm in re.finditer(
            r'SPINAND_INFO\(\s*"([^"]+)"\s*,\s*SPINAND_ID\(\s*SPINAND_READID_METHOD_[A-Z_]+\s*,'
            r'((?:\s*0x[0-9a-fA-F]+\s*,?)+)\s*\)', src):
        name = pm.group(1)
        ids = [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', pm.group(2))]
        if not ids:
            continue
        # Some vendor tables lead with the manufacturer byte, some go straight
        # to the device byte. flash_type is always the device byte.
        dev = ids[1] if (len(ids) > 1 and ids[0] == mb) else ids[0]
        parts.append((mb, dev, name, vendor))

parts.sort(key=lambda p: (p[3].lower(), p[0], p[1]))

# ---- the two entries this board is known to need, on real hardware ----------
have = {(mb, dev) for mb, dev, _, _ in parts}
for need, why in (((0xc8, 0x11), "the common ESMT part"),
                  ((0xef, 0xbe), "the Winbond second source, 4d074a2")):
    if need not in have:
        sys.exit("ERROR: this kernel has no spinand entry for %02x:%02x (%s) — "
                 "refusing to publish a support list that omits a part this "
                 "board is known to ship" % (need[0], need[1], why))

supported = [p for p in parts if (p[0], p[1]) in BOOTLOADER]
other = [p for p in parts if (p[0], p[1]) not in BOOTLOADER]
missing = sorted(k for k in BOOTLOADER if k not in have)

w = sys.stdout.write
w("# NAND parts this OpenWrt build can drive - Xiaomi AX3000T / RD03v2 (IPQ5018)\n")
w("#\n")
w("# Generated by tools/mknand-support.sh from the kernel that was actually\n")
w("# built (Linux %s, drivers/mtd/nand/spi, vendor tables: %s).\n" % (kver, ", ".join(built)))
w("#\n")
w("# Format, one part per line, '#' starts a comment:\n")
w("#\n")
w("#     <flash_type>  <mfr:dev>  <part>\n")
w("#\n")
w("# flash_type is the device byte the stock bootloader leaves in the U-Boot\n")
w("# environment after it probes the chip. That is how a unit self-identifies\n")
w("# BEFORE anything is flashed:\n")
w("#\n")
w("#     fw_printenv flash_type      # OpenWrt\n")
w("#     nvram get flash_type        # stock firmware\n")
w("#\n")
w("# An installer should read that byte and require a matching line here:\n")
w("#\n")
w("#     ft=$(fw_printenv -n flash_type)\n")
w("#     grep -qi \"^${ft}[[:space:]]\" nand-support.txt || abort\n")
w("#\n")
w("# A flash_type of '-' means the kernel knows the part but the stock\n")
w("# bootloader has no ID for it. Such a chip cannot be this board's boot NAND\n")
w("# (the bootloader could not read it to boot in the first place), so those\n")
w("# lines are informational: the driver would handle the part, this board\n")
w("# will never present it.\n")
w("#\n")
w("# %d of the %d parts in the bootloader's own table are supported.\n"
  % (len(supported), len(BOOTLOADER)))
if missing:
    w("# Not supported by this build (bootloader knows them, the kernel does not):\n")
    for mb, dev in missing:
        w("#     %02x  %02x:%02x  %s\n" % (dev, mb, dev, BOOTLOADER[(mb, dev)]))
w("#\n")
w("# --- parts the stock bootloader can also identify ---------------------------\n")
for mb, dev, name, vendor in sorted(supported, key=lambda p: p[1]):
    boot = BOOTLOADER[(mb, dev)]
    note = "" if boot.split()[-1].startswith(name[:6]) else "   # bootloader: %s" % boot
    w("%02x  %02x:%02x  %s %s%s\n" % (dev, mb, dev, vendor, name, note))
w("\n")
w("# --- other parts this driver knows (not reachable on this board) ------------\n")
for mb, dev, name, vendor in other:
    w("-   %02x:%02x  %s %s\n" % (mb, dev, vendor, name))
PY
