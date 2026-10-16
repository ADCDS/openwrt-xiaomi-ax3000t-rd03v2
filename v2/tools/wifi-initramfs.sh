#!/usr/bin/env bash
# wifi-initramfs.sh — produce the release's "-wifi" initramfs artifacts from an
# already-finished build tree, by re-running ONLY the image step with the
# beaconing rc.local (installer-wifi.rc.local, next to this script) in place.
#
# WHY THIS EXISTS
#   The RAM initramfs is the only sanctioned way to write this board's NAND, but
#   it comes up with both radios disabled, so a flash needs a LAN cable. A
#   variant whose initramfs beacons makes a fully over-the-air install possible.
#   That is a one-file difference in the rootfs, so the tree is built once and
#   the *image step* runs a second time with the extra rc.local. The kernel is
#   not reconfigured, so vermagic (an md5 over the kernel config) is unchanged
#   and the release's kernel modules install on both installers. This script
#   asserts that rather than assuming it.
#
#   Only the initramfs artifacts are kept from the second pass; the squashfs
#   images it also regenerates are thrown away and the tree is put back exactly
#   as it was, so mkrelease-v2.sh still sees one coherent tree.
#
#   Usage:  v2/tools/wifi-initramfs.sh /path/to/finished/v2/tree
#   (finish-build-v2.sh runs it through wifi-initramfs-v2.sh)
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT=${WIFI_FRAGMENT:-$HERE/installer-wifi.rc.local}
JOBS=${JOBS:-2}
EXTRACT="$HERE/initramfs-extract.sh"

TREE="${1:-${TREE:-}}"
[ -n "$TREE" ] || { echo "usage: $0 /path/to/openwrt" >&2; exit 2; }
TREE="$(cd "$TREE" && pwd)"

T=bin/targets/qualcommax/ipq50xx
PREFIX=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2
RCL=${WIFI_RCL:-target/linux/qualcommax/ipq50xx/base-files/etc/rc.local}
STASH="$TREE/.wifi-pass-stash"

# The functional payload of the fragment, not one of its comments: if someone
# ever trims the comments this must still be the thing being looked for.
MARKER='OpenWrt-RD03v2-Installer'

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$FRAGMENT" ] || die "missing $FRAGMENT"
[ -x "$EXTRACT" ]  || die "missing or non-executable $EXTRACT"
case "$JOBS" in 1|2) ;; *) die "JOBS must be 1 or 2" ;; esac
case "$RCL" in /*|../*|*/../*|*/..) die "WIFI_RCL must name a file within the tree" ;; esac
[ -f "$TREE/$RCL" ] || die "$TREE: no $RCL — is this a tree built by build.sh?"
for i in initramfs-uImage.itb initramfs-factory.ubi; do
	[ -f "$TREE/$T/$PREFIX-$i" ] || die "$TREE: missing $PREFIX-$i — build the tree first"
done
[ -e "$TREE/$T/$PREFIX-initramfs-uImage-wifi.itb" ] \
	&& die "$TREE already carries -wifi artifacts; remove them to redo the pass"
[ -e "$STASH" ] && die "$STASH exists — a previous pass did not finish; inspect it first"

# ---------------------------------------------------------------- 0. baseline
echo ">>> baseline: reading /etc/rc.local out of the non-wifi initramfs"
BEFORE_RCL=$(mktemp)
AFTER_RCL= WIFI_TMP= RESTORE_NEEDED=0
cleanup() {
	local status=$?
	trap - EXIT
	if [ "$RESTORE_NEEDED" = 1 ]; then
		restore || status=1
	fi
	rm -f "$BEFORE_RCL" "${AFTER_RCL:-}"
	[ -z "$WIFI_TMP" ] || rm -rf "$WIFI_TMP"
	exit "$status"
}
trap cleanup EXIT
"$EXTRACT" "$TREE/$T/$PREFIX-initramfs-uImage.itb" etc/rc.local > "$BEFORE_RCL" \
	|| die "could not read etc/rc.local out of the existing initramfs"
if grep -q "$MARKER" "$BEFORE_RCL"; then
	die "the NON-wifi initramfs already beacons — the image's rc.local must stay radio-silent"
fi
BEFORE_SUM=$(sha256sum <"$TREE/$T/$PREFIX-initramfs-uImage.itb" | cut -d' ' -f1)
BEFORE_KVER=$(cd "$TREE" && ls "$T/packages/"kernel-*.apk 2>/dev/null | head -n1)
BEFORE_KVER=${BEFORE_KVER##*/kernel-}; BEFORE_KVER=${BEFORE_KVER%.apk}
[ -n "$BEFORE_KVER" ] || die "no kernel-*.apk in $T/packages — is the build finished?"
echo "    kernel $BEFORE_KVER"

# ------------------------------------------------------------------- 1. stash
# Put back everything the image step rewrites, so the finished tree differs from
# the non-wifi build by exactly the two extra artifacts and nothing else.
echo ">>> stashing the non-wifi artifacts"
mkdir -p "$STASH/top" "$STASH/pkgs"
find "$TREE/$T" -maxdepth 1 -type f -exec cp -a -t "$STASH/top" {} +
find "$TREE/$T/packages" -maxdepth 1 -type f \( ! -name '*.apk' -o -name 'base-files-*.apk' -o -name 'kernel-*.apk' \) -exec cp -a -t "$STASH/pkgs" {} +
(cd "$TREE/$T/packages" && find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum) > "$STASH/packages.sha256"
if [ -d "$TREE/staging_dir/packages/qualcommax" ]; then
	cp -a "$TREE/staging_dir/packages/qualcommax" "$STASH/merged"
fi
cp -a "$TREE/$RCL" "$STASH/rc.local.orig"
RESTORE_NEEDED=1

# Keep the stash on any error, including an incomplete restoration.
restore() {
	echo ">>> restoring the tree to its non-wifi state"
	cp -a "$STASH/rc.local.orig" "$TREE/$RCL" || return 1
	cp -a "$STASH/top/." "$TREE/$T/" || return 1
	find "$TREE/$T/packages" -maxdepth 1 -type f \( -name 'base-files-*.apk' -o -name 'kernel-*.apk' \) -delete || return 1
	if [ -n "$(ls -A "$STASH/pkgs" 2>/dev/null)" ]; then
		cp -a "$STASH/pkgs/." "$TREE/$T/packages/" || return 1
	fi
	if [ -d "$STASH/merged" ]; then
		rm -rf "$TREE/staging_dir/packages/qualcommax" || return 1
		cp -a "$STASH/merged" "$TREE/staging_dir/packages/qualcommax" || return 1
	fi
	RESTORE_NEEDED=0
	return 0
}

# ------------------------------------------------------------------ 2. insert
# Additive, above the final "exit 0". Any /proc/sys/dev/nss knob lines the file
# carries (v1.x's NSS build prepended some; v2's has none) must come out
# unchanged: check, rather than trust, that we are editing the file we think we are.
echo ">>> inserting the beaconing block into $RCL"
# grep -c exits 1 on zero matches; that is a reason to report the anchor as
# missing, not to die without saying so.
n=$(grep -c '^exit 0$' "$TREE/$RCL" || true)
[ "$n" = "1" ] || { restore; die "anchor '^exit 0$' matched $n times (want 1) in $TREE/$RCL"; }
grep -q "$MARKER" "$TREE/$RCL" && { restore; die "$TREE/$RCL already carries the block"; }
# Match knob lines, not the string anywhere in the file: a looser pattern
# would count prose in a comment as a knob.
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
	|| { restore; die "the insert disturbed the file's NSS knob lines ($NSS_LINES_BEFORE -> $NSS_LINES_AFTER)"; }
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
	make -j"$JOBS" package/base-files/compile || exit 1
	make -j"$JOBS" package/install      || exit 1
	make -j"$JOBS" target/install       || exit 1
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
(cd "$TREE/$T/packages" && find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum) > "$STASH/packages-restored.sha256"
cmp -s "$STASH/packages.sha256" "$STASH/packages-restored.sha256" \
	|| die "package/index bytes changed after restore (stash left at $STASH)"
cmp -s "$STASH/rc.local.orig" "$TREE/$RCL" || die "rc.local restoration failed (stash left at $STASH)"
rm -rf "$STASH"

echo
echo "$TREE/$T now holds both passes:"
( cd "$TREE/$T" && ls -l $PREFIX-initramfs-* )
