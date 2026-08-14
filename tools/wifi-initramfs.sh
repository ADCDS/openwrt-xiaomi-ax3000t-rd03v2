#!/usr/bin/env bash
# wifi-initramfs.sh — produce the release's "-wifi" initramfs artifacts from an
# already-finished build tree, by re-running ONLY the image step with the
# beaconing rc.local (tools/installer-wifi.rc.local) in place.
#
# WHY THIS EXISTS
#   The RAM initramfs is the only sanctioned way to write this board's NAND, but
#   it comes up with both radios disabled, so a flash needs a LAN cable. A
#   variant whose initramfs beacons makes a fully over-the-air install possible.
#   That is a one-file difference in the rootfs — a whole third and fourth build
#   tree for it would cost hours and a KMODS=1 tree's worth of disk, and would
#   produce kmods that pair with nothing.
#
#   So each tree is built once (KMODS=1) and the *image step* is run a second
#   time with the extra rc.local. The kernel is not reconfigured, so vermagic —
#   an md5 over the kernel config — is unchanged and the tree's single kmod set
#   still installs on both passes' images. This script asserts that rather than
#   assuming it.
#
#   Only the initramfs artifacts are kept from the second pass; the squashfs
#   images it also regenerates are thrown away and the tree is put back exactly
#   as it was, so tools/mkrelease.sh still sees one coherent tree.
#
#   Usage:  ./tools/wifi-initramfs.sh /path/to/rel-v17-default/openwrt
#
#   Leaves, next to the originals:
#     …-initramfs-uImage-wifi.itb
#     …-initramfs-factory-wifi.ubi
#
# THE FAILURE MODE THIS GUARDS AGAINST
#   A second pass that silently produced a byte-identical image. Every plausible
#   way for that to happen (the make invocation not actually rebuilding the
#   rootfs; the insert landing in a file the image does not use; a stale stamp)
#   ends in the same place: two identical artifacts with different names, and
#   users flashing a "wifi" installer that never beacons. So the pass is not
#   complete until the two images are proven to differ AND the beaconing block
#   is read back out of the new one and shown to be absent from the old one.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENT="$REPO/tools/installer-wifi.rc.local"
EXTRACT="$REPO/tools/initramfs-extract.sh"

TREE="${1:-${TREE:-}}"
[ -n "$TREE" ] || { echo "usage: $0 /path/to/openwrt" >&2; exit 2; }
TREE="$(cd "$TREE" && pwd)"

T=bin/targets/qualcommax/ipq50xx
PREFIX=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2
RCL=target/linux/qualcommax/ipq50xx/base-files/etc/rc.local
STASH="$TREE/.wifi-pass-stash"

# The functional payload of the fragment, not one of its comments: if someone
# ever trims the comments this must still be the thing being looked for.
MARKER='OpenWrt-RD03v2-Installer'

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$FRAGMENT" ] || die "missing $FRAGMENT"
[ -x "$EXTRACT" ]  || die "missing or non-executable $EXTRACT"
[ -f "$TREE/$RCL" ] || die "$TREE: no $RCL — is this a tree built by build.sh?"
for i in initramfs-uImage.itb initramfs-factory.ubi; do
	[ -f "$TREE/$T/$PREFIX-$i" ] || die "$TREE: missing $PREFIX-$i — build the tree first"
done
[ -e "$TREE/$T/$PREFIX-initramfs-uImage-wifi.itb" ] \
	&& die "$TREE already carries -wifi artifacts; remove them to redo the pass"
[ -e "$STASH" ] && die "$STASH exists — a previous pass did not finish; inspect it first"

# ---------------------------------------------------------------- 0. baseline
echo ">>> baseline: reading /etc/rc.local out of the non-wifi initramfs"
BEFORE_RCL=$(mktemp); trap 'rm -f "$BEFORE_RCL"' EXIT
"$EXTRACT" "$TREE/$T/$PREFIX-initramfs-uImage.itb" etc/rc.local > "$BEFORE_RCL" \
	|| die "could not read etc/rc.local out of the existing initramfs"
if grep -q "$MARKER" "$BEFORE_RCL"; then
	die "the NON-wifi initramfs already beacons — files/ must stay radio-silent"
fi
BEFORE_SUM=$(sha256sum <"$TREE/$T/$PREFIX-initramfs-uImage.itb" | cut -d' ' -f1)
BEFORE_KVER=$(cd "$TREE" && ls "$T/packages/"kernel-*.apk 2>/dev/null | head -n1)
BEFORE_KVER=${BEFORE_KVER##*/kernel-}; BEFORE_KVER=${BEFORE_KVER%.apk}
[ -n "$BEFORE_KVER" ] || die "no kernel-*.apk in $T/packages — tree not built with KMODS=1?"
echo "    kernel $BEFORE_KVER"

# ------------------------------------------------------------------- 1. stash
# Put back everything the image step rewrites, so the finished tree differs from
# the non-wifi build by exactly the two extra artifacts and nothing else.
echo ">>> stashing the non-wifi artifacts"
mkdir -p "$STASH/top" "$STASH/pkgs"
find "$TREE/$T" -maxdepth 1 -type f -exec cp -a {} "$STASH/top/" \;
find "$TREE/$T/packages" -maxdepth 1 -type f ! -name '*.apk' -exec cp -a {} "$STASH/pkgs/" \; 2>/dev/null || true
cp -a "$TREE/$T/packages/"base-files-*.apk "$STASH/pkgs/" 2>/dev/null || true
if [ -d "$TREE/staging_dir/packages/qualcommax" ]; then
	cp -a "$TREE/staging_dir/packages/qualcommax" "$STASH/merged"
fi
cp -a "$TREE/$RCL" "$STASH/rc.local.orig"

# Must always succeed: every caller is "restore; die <why>", and a restore that
# returned non-zero under set -e would swallow the message explaining what went
# wrong.
restore() {
	echo ">>> restoring the tree to its non-wifi state"
	cp -a "$STASH/rc.local.orig" "$TREE/$RCL"
	cp -a "$STASH/top/." "$TREE/$T/"
	if [ -n "$(ls -A "$STASH/pkgs" 2>/dev/null)" ]; then
		cp -a "$STASH/pkgs/." "$TREE/$T/packages/"
	fi
	if [ -d "$STASH/merged" ]; then
		rm -rf "$TREE/staging_dir/packages/qualcommax"
		cp -a "$STASH/merged" "$TREE/staging_dir/packages/qualcommax"
	fi
	return 0
}

# ------------------------------------------------------------------ 2. insert
# Additive, above the final "exit 0". build.sh (NSS=1) *prepends* its
# /proc/sys/dev/nss knobs to line 1 of this same file, so the two never collide
# — but check, rather than trust, that we are editing the file we think we are.
echo ">>> inserting the beaconing block into $RCL"
# grep -c exits 1 on zero matches; that is a reason to report the anchor as
# missing, not to die without saying so.
n=$(grep -c '^exit 0$' "$TREE/$RCL" || true)
[ "$n" = "1" ] || { restore; die "anchor '^exit 0$' matched $n times (want 1) in $TREE/$RCL"; }
grep -q "$MARKER" "$TREE/$RCL" && { restore; die "$TREE/$RCL already carries the block"; }
# Match the knobs build.sh actually prepends, not the string anywhere in the
# file: the inserted block *documents* that interaction in a comment, and a
# looser pattern counts the prose as a knob.
NSS_KNOB='^echo 1 > /proc/sys/dev/nss/'
NSS_LINES_BEFORE=$(grep -c "$NSS_KNOB" "$TREE/$RCL" || true)

python3 - "$TREE/$RCL" "$FRAGMENT" <<'PY'
import sys
rcl, frag = sys.argv[1], sys.argv[2]
body = open(rcl).read()
block = open(frag).read()
if not block.endswith('\n'):
    block += '\n'
i = body.rindex('exit 0')
open(rcl, 'w').write(body[:i] + block + '\n' + body[i:])
PY

grep -q "$MARKER" "$TREE/$RCL" || { restore; die "insert did not take"; }
NSS_LINES_AFTER=$(grep -c "$NSS_KNOB" "$TREE/$RCL" || true)
[ "$NSS_LINES_BEFORE" = "$NSS_LINES_AFTER" ] \
	|| { restore; die "the insert disturbed the NSS knobs build.sh prepended ($NSS_LINES_BEFORE -> $NSS_LINES_AFTER)"; }
echo "    ok (NSS knob lines preserved: $NSS_LINES_AFTER)"

# --------------------------------------------------------------- 3. re-image
# base-files carries target/linux/.../base-files, so it is the package that has
# to be rebuilt; its stamp does not track that directory's mtimes, hence clean.
# package/install then rebuilds the rootfs staging dir, and target/install
# relinks the kernel around the new initramfs and regenerates the images. The
# kernel *configuration* is untouched, so vermagic cannot move — asserted below.
echo ">>> re-running the image step (base-files -> rootfs -> images)"
# Explicit `|| exit` on each step: bash suppresses set -e inside a subshell that
# is part of an || list, so without them a failing early step would let the rest
# run and only the last one's status would be seen.
(
	cd "$TREE" || exit 1
	rm -f staging_dir/target-*/stamp/.package_install staging_dir/target-*/stamp/.target_install
	make package/base-files/clean          || exit 1
	make -j"$(nproc)" package/base-files/compile || exit 1
	make -j"$(nproc)" package/install      || exit 1
	make -j"$(nproc)" target/install       || exit 1
) || { restore; die "the image step failed"; }

# ------------------------------------------------------------------ 4. verify
echo ">>> verifying the second pass actually produced a different image"
AFTER_SUM=$(sha256sum <"$TREE/$T/$PREFIX-initramfs-uImage.itb" | cut -d' ' -f1)
[ "$AFTER_SUM" != "$BEFORE_SUM" ] \
	|| { restore; die "the -wifi pass produced a byte-identical initramfs — the image step did not pick the change up"; }

AFTER_RCL=$(mktemp)
"$EXTRACT" "$TREE/$T/$PREFIX-initramfs-uImage.itb" etc/rc.local > "$AFTER_RCL" \
	|| { rm -f "$AFTER_RCL"; restore; die "could not read etc/rc.local back out of the new initramfs"; }
grep -q "$MARKER" "$AFTER_RCL" \
	|| { rm -f "$AFTER_RCL"; restore; die "the new initramfs does not contain the beaconing block"; }
grep -q 'rootfs_type\|/proc/mounts' "$AFTER_RCL" \
	|| { rm -f "$AFTER_RCL"; restore; die "the new initramfs's rc.local lost the tmpfs gate"; }

AFTER_KVER=$(cd "$TREE" && ls "$T/packages/"kernel-*.apk 2>/dev/null | head -n1)
AFTER_KVER=${AFTER_KVER##*/kernel-}; AFTER_KVER=${AFTER_KVER%.apk}
[ "$AFTER_KVER" = "$BEFORE_KVER" ] \
	|| { rm -f "$AFTER_RCL"; restore; die "vermagic moved ($BEFORE_KVER -> $AFTER_KVER) — the kmod tarball would pair with only one pass"; }

echo "    non-wifi rc.local: $(wc -l <"$BEFORE_RCL") lines, no beacon"
echo "    -wifi    rc.local: $(wc -l <"$AFTER_RCL") lines, beacon present"
echo "    kernel unchanged:  $AFTER_KVER"
rm -f "$AFTER_RCL"

# --------------------------------------------------------------- 5. keep/undo
echo ">>> keeping the -wifi initramfs artifacts, discarding the rest of the pass"
WIFI_TMP=$(mktemp -d)
cp -a "$TREE/$T/$PREFIX-initramfs-uImage.itb"   "$WIFI_TMP/$PREFIX-initramfs-uImage-wifi.itb"
cp -a "$TREE/$T/$PREFIX-initramfs-factory.ubi"  "$WIFI_TMP/$PREFIX-initramfs-factory-wifi.ubi"
restore
mv "$WIFI_TMP/$PREFIX-initramfs-uImage-wifi.itb"  "$TREE/$T/"
mv "$WIFI_TMP/$PREFIX-initramfs-factory-wifi.ubi" "$TREE/$T/"
rmdir "$WIFI_TMP"

# The restore must have put the non-wifi image back byte-for-byte, or the tree
# now holds a squashfs from one pass and an initramfs from another.
NOW_SUM=$(sha256sum <"$TREE/$T/$PREFIX-initramfs-uImage.itb" | cut -d' ' -f1)
[ "$NOW_SUM" = "$BEFORE_SUM" ] || die "restore did not put the non-wifi initramfs back (stash left at $STASH)"
rm -rf "$STASH"

echo
echo "$TREE/$T now holds both passes:"
( cd "$TREE/$T" && ls -l $PREFIX-initramfs-* )
